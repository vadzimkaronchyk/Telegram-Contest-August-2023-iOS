import Foundation
import UIKit
import Postbox
import TelegramCore
import SyncCore
import SwiftSignalKit
import Display
import AVFoundation
import TelegramVoip
import TelegramAudio
import TelegramUIPreferences
import TelegramPresentationData
import DeviceAccess
import UniversalMediaPlayer
import AccountContext

private extension PresentationGroupCallState {
    static var initialValue: PresentationGroupCallState {
        return PresentationGroupCallState(
            networkState: .connecting,
            isMuted: true
        )
    }
}

public final class PresentationGroupCallImpl: PresentationGroupCall {
    private enum InternalState {
        case requesting
        case active(GroupCallInfo)
        case estabilished(GroupCallInfo, String, [UInt32: PeerId])
        
        var callInfo: GroupCallInfo? {
            switch self {
            case .requesting:
                return nil
            case let .active(info):
                return info
            case let .estabilished(info, _, _):
                return info
            }
        }
    }
    
    public let account: Account
    public let accountContext: AccountContext
    private let audioSession: ManagedAudioSession
    private let callKitIntegration: CallKitIntegration?
    public var isIntegratedWithCallKit: Bool {
        return self.callKitIntegration != nil
    }
    
    private let getDeviceAccessData: () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void)
    
    public let internalId: CallSessionInternalId
    public let peerId: PeerId
    public let peer: Peer?
    
    private var internalState: InternalState = .requesting
    
    private var callContext: OngoingGroupCallContext?
    private var ssrcMapping: [UInt32: PeerId] = [:]
    
    private var sessionStateDisposable: Disposable?
    
    private let isMutedPromise = ValuePromise<Bool>(true)
    private var isMutedValue = true
    public var isMuted: Signal<Bool, NoError> {
        return self.isMutedPromise.get()
    }
    
    private let audioOutputStatePromise = Promise<([AudioSessionOutput], AudioSessionOutput?)>(([], nil))
    private var audioOutputStateValue: ([AudioSessionOutput], AudioSessionOutput?) = ([], nil)
    private var currentAudioOutputValue: AudioSessionOutput = .builtin
    public var audioOutputState: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> {
        return self.audioOutputStatePromise.get()
    }
    
    private var audioSessionControl: ManagedAudioSessionControl?
    private var audioSessionDisposable: Disposable?
    private let audioSessionShouldBeActive = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var audioSessionShouldBeActiveDisposable: Disposable?
    private let audioSessionActive = Promise<Bool>(false)
    private var audioSessionActiveDisposable: Disposable?
    private var isAudioSessionActive = false
    
    private let _canBeRemoved = Promise<Bool>(false)
    public var canBeRemoved: Signal<Bool, NoError> {
        return self._canBeRemoved.get()
    }
    
    private var stateValue = PresentationGroupCallState.initialValue {
        didSet {
            if self.stateValue != oldValue {
                self.statePromise.set(self.stateValue)
            }
        }
    }
    private let statePromise = ValuePromise<PresentationGroupCallState>(PresentationGroupCallState.initialValue)
    public var state: Signal<PresentationGroupCallState, NoError> {
        return self.statePromise.get()
    }
    
    private var membersValue: [PeerId: PresentationGroupCallMemberState] = [:] {
        didSet {
            if self.membersValue != oldValue {
                self.membersPromise.set(self.membersValue)
            }
        }
    }
    private let membersPromise = ValuePromise<[PeerId: PresentationGroupCallMemberState]>([:])
    public var members: Signal<[PeerId: PresentationGroupCallMemberState], NoError> {
        return self.membersPromise.get()
    }
    
    private let requestDisposable = MetaDisposable()
    private var groupCallParticipantUpdatesDisposable: Disposable?
    
    private let networkStateDisposable = MetaDisposable()
    private let isMutedDisposable = MetaDisposable()
    private let memberStatesDisposable = MetaDisposable()
    private let leaveDisposable = MetaDisposable()
    
    init(
        accountContext: AccountContext,
        audioSession: ManagedAudioSession,
        callKitIntegration: CallKitIntegration?,
        getDeviceAccessData: @escaping () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void),
        internalId: CallSessionInternalId,
        peerId: PeerId,
        peer: Peer?
    ) {
        self.account = accountContext.account
        self.accountContext = accountContext
        self.audioSession = audioSession
        self.callKitIntegration = callKitIntegration
        self.getDeviceAccessData = getDeviceAccessData
        
        self.internalId = internalId
        self.peerId = peerId
        self.peer = peer
        
        var didReceiveAudioOutputs = false
        
        self.audioSessionDisposable = audioSession.push(audioSessionType: .voiceCall, manualActivate: { [weak self] control in
            Queue.mainQueue().async {
                if let strongSelf = self {
                    strongSelf.updateSessionState(internalState: strongSelf.internalState, audioSessionControl: control)
                }
            }
        }, deactivate: { [weak self] in
            return Signal { subscriber in
                Queue.mainQueue().async {
                    if let strongSelf = self {
                        strongSelf.updateIsAudioSessionActive(false)
                        strongSelf.updateSessionState(internalState: strongSelf.internalState, audioSessionControl: nil)
                    }
                    subscriber.putCompletion()
                }
                return EmptyDisposable
            }
        }, availableOutputsChanged: { [weak self] availableOutputs, currentOutput in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.audioOutputStateValue = (availableOutputs, currentOutput)
                
                var signal: Signal<([AudioSessionOutput], AudioSessionOutput?), NoError> = .single((availableOutputs, currentOutput))
                if !didReceiveAudioOutputs {
                    didReceiveAudioOutputs = true
                    if currentOutput == .speaker {
                        signal = .single((availableOutputs, .builtin))
                        |> then(
                            signal
                            |> delay(1.0, queue: Queue.mainQueue())
                        )
                    }
                }
                strongSelf.audioOutputStatePromise.set(signal)
            }
        })
        
        self.audioSessionShouldBeActiveDisposable = (self.audioSessionShouldBeActive.get()
        |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self {
                if value {
                    if let audioSessionControl = strongSelf.audioSessionControl {
                        let audioSessionActive: Signal<Bool, NoError>
                        if let callKitIntegration = strongSelf.callKitIntegration {
                            audioSessionActive = callKitIntegration.audioSessionActive
                            |> filter { $0 }
                            |> timeout(2.0, queue: Queue.mainQueue(), alternate: Signal { subscriber in
                                if let strongSelf = self, let _ = strongSelf.audioSessionControl {
                                }
                                subscriber.putNext(true)
                                subscriber.putCompletion()
                                return EmptyDisposable
                            })
                        } else {
                            audioSessionControl.activate({ _ in })
                            audioSessionActive = .single(true)
                        }
                        strongSelf.audioSessionActive.set(audioSessionActive)
                    } else {
                        strongSelf.audioSessionActive.set(.single(false))
                    }
                } else {
                    strongSelf.audioSessionActive.set(.single(false))
                }
            }
        })
        
        self.audioSessionActiveDisposable = (self.audioSessionActive.get()
        |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self {
                strongSelf.updateIsAudioSessionActive(value)
            }
        })
        
        self.requestCall()
        
        self.groupCallParticipantUpdatesDisposable = (self.account.stateManager.groupCallParticipantUpdates
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let strongSelf = self else {
                return
            }
            if case let .estabilished(callInfo, _, _) = strongSelf.internalState {
                var addedSsrc: [UInt32] = []
                for (callId, peerId, ssrc, _) in updates {
                    if callId == callInfo.id {
                        let mappedSsrc = UInt32(bitPattern: ssrc)
                        addedSsrc.append(mappedSsrc)
                        strongSelf.ssrcMapping[mappedSsrc] = peerId
                    }
                }
                if !addedSsrc.isEmpty {
                    strongSelf.callContext?.addSsrcs(ssrcs: addedSsrc)
                }
            }
        })
    }
    
    deinit {
        self.audioSessionShouldBeActiveDisposable?.dispose()
        self.audioSessionActiveDisposable?.dispose()
        self.sessionStateDisposable?.dispose()
        self.audioSessionDisposable?.dispose()
        self.requestDisposable.dispose()
        self.groupCallParticipantUpdatesDisposable?.dispose()
        self.leaveDisposable.dispose()
        self.isMutedDisposable.dispose()
        self.memberStatesDisposable.dispose()
        self.networkStateDisposable.dispose()
    }
    
    private func updateSessionState(internalState: InternalState, audioSessionControl: ManagedAudioSessionControl?) {
        let previousControl = self.audioSessionControl
        self.audioSessionControl = audioSessionControl
        
        let previousInternalState = self.internalState
        self.internalState = internalState
        
        if let audioSessionControl = audioSessionControl, previousControl == nil {
            audioSessionControl.setOutputMode(.custom(self.currentAudioOutputValue))
            audioSessionControl.setup(synchronous: true)
        }
        
        self.audioSessionShouldBeActive.set(true)
        
        switch previousInternalState {
        case .active:
            break
        default:
            if case let .active(callInfo) = internalState {
                let callContext = OngoingGroupCallContext()
                self.callContext = callContext
                self.requestDisposable.set((callContext.joinPayload
                |> take(1)
                |> deliverOnMainQueue).start(next: { [weak self] joinPayload in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.requestDisposable.set((joinGroupCall(
                        account: strongSelf.account,
                        callId: callInfo.id,
                        accessHash: callInfo.accessHash,
                        joinPayload: joinPayload
                    )
                    |> deliverOnMainQueue).start(next: { joinCallResult in
                        guard let strongSelf = self else {
                            return
                        }
                        if let clientParams = joinCallResult.callInfo.clientParams {
                            strongSelf.updateSessionState(internalState: .estabilished(joinCallResult.callInfo, clientParams, joinCallResult.ssrcMapping), audioSessionControl: strongSelf.audioSessionControl)
                        }
                    }))
                }))
                
                self.isMutedDisposable.set((callContext.isMuted
                |> deliverOnMainQueue).start(next: { [weak self] isMuted in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.stateValue.isMuted = isMuted
                }))
                
                self.networkStateDisposable.set((callContext.networkState
                |> deliverOnMainQueue).start(next: { [weak self] state in
                    guard let strongSelf = self else {
                        return
                    }
                    let mappedState: PresentationGroupCallState.NetworkState
                    switch state {
                    case .connecting:
                        mappedState = .connecting
                    case .connected:
                        mappedState = .connected
                    }
                    strongSelf.stateValue.networkState = mappedState
                }))
                
                self.memberStatesDisposable.set((callContext.memberStates
                |> deliverOnMainQueue).start(next: { [weak self] memberStates in
                    guard let strongSelf = self else {
                        return
                    }
                    var result: [PeerId: PresentationGroupCallMemberState] = [:]
                    for (ssrc, _) in memberStates {
                        if let peerId = strongSelf.ssrcMapping[ssrc] {
                            result[peerId] = PresentationGroupCallMemberState(
                                ssrc: ssrc,
                                isSpeaking: false
                            )
                        }
                    }
                    strongSelf.membersValue = result
                }))
            }
        }
        
        switch previousInternalState {
        case .estabilished:
            break
        default:
            if case let .estabilished(_, clientParams, ssrcMapping) = internalState {
                self.ssrcMapping = ssrcMapping
                self.callContext?.setJoinResponse(payload: clientParams, ssrcs: Array(ssrcMapping.keys))
            }
        }
    }
    
    private func updateIsAudioSessionActive(_ value: Bool) {
        if self.isAudioSessionActive != value {
            self.isAudioSessionActive = value
        }
    }
    
    public func leave() -> Signal<Bool, NoError> {
        if case let .estabilished(callInfo, _, _) = self.internalState {
            self.leaveDisposable.set((leaveGroupCall(account: self.account, callId: callInfo.id, accessHash: callInfo.accessHash)
            |> deliverOnMainQueue).start(completed: { [weak self] in
                self?._canBeRemoved.set(.single(true))
            }))
        } else {
        }
        return self._canBeRemoved.get()
    }
    
    public func toggleIsMuted() {
        self.setIsMuted(!self.isMutedValue)
    }
    
    public func setIsMuted(_ value: Bool) {
        self.isMutedValue = value
        self.isMutedPromise.set(self.isMutedValue)
        self.callContext?.setIsMuted(self.isMutedValue)
    }
    
    public func setCurrentAudioOutput(_ output: AudioSessionOutput) {
        guard self.currentAudioOutputValue != output else {
            return
        }
        self.currentAudioOutputValue = output
        
        self.audioOutputStatePromise.set(.single((self.audioOutputStateValue.0, output))
        |> then(
            .single(self.audioOutputStateValue)
            |> delay(1.0, queue: Queue.mainQueue())
        ))
        
        if let audioSessionControl = self.audioSessionControl {
            audioSessionControl.setOutputMode(.custom(output))
        }
    }
    
    private func requestCall() {
        self.internalState = .requesting
        
        enum CallError {
            case generic
        }
        
        let account = self.account
        let peerId = self.peerId
        
        let currentCall = getCurrentGroupCall(account: account, peerId: peerId)
        |> mapError { _ -> CallError in
            return .generic
        }
        
        let currentOrRequestedCall = currentCall
        |> mapToSignal { callInfo -> Signal<GroupCallInfo, CallError> in
            if let callInfo = callInfo {
                return .single(callInfo)
            } else {
                return createGroupCall(account: account, peerId: peerId)
                |> mapError { _ -> CallError in
                    return .generic
                }
            }
        }
        
        let restartedCall = currentOrRequestedCall
        |> mapToSignal { value -> Signal<GroupCallInfo, CallError> in
            let stopped: Signal<GroupCallInfo, CallError> = stopGroupCall(account: account, callId: value.id, accessHash: value.accessHash)
            |> mapError { _ -> CallError in
                return .generic
            }
            |> map { _ -> GroupCallInfo in
            }
                
            return stopped
            |> then(currentOrRequestedCall)
        }
        
        self.requestDisposable.set((currentOrRequestedCall
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            strongSelf.updateSessionState(internalState: .active(value), audioSessionControl: strongSelf.audioSessionControl)
        }))
    }
}