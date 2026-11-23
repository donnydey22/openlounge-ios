// CallCenter — CallKit + PushKit for Open Lounge calls.
//
//   VoIP push (server voipPayload)  -> reportNewIncomingCall (always, at once, as iOS requires)
//   page call:incoming (app not in front) -> same CallKit call (deterministic UUID per call id)
//   system Answer                   -> the page accepts on its own socket; media follows
//   system Decline                  -> POST /api/calls/<id>/decline with the ring's decline token
//   system End / Mute               -> the page hangs up / mutes; media ends with it
//   page call:outgoing / connected  -> CXStartCallAction / reportOutgoingCall(connectedAt:)
//   page call:ended, ring cancel, ring expiry -> reportCall(endedAt:)
//
// CallKit activates the audio session; didActivate / didDeactivate go to the engine's
// OLCallAudioDevice (the only code that touches AVAudioSession during a call).
import AVFAudio
import CallKit
import Foundation
import OLShellCore
import OLCallCore
import PushKit
import UIKit

final class CallCenter: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
    static let shared = CallCenter()

    private struct Entry {
        let uuid: UUID
        let incoming: Bool
        let invitationId: String?
        var answered = false
        var accepting = false
        var answeredInPage = false
        var answerAction: CXAnswerCallAction?
        var declineToken: String?
        var expiresAtMs: Double
        var name: String
        var video: Bool
    }

    private static let acceptTimeout: TimeInterval = 20

    weak var host: ShellHost?
    /// Main queue: PushKit token (hex) changed.
    var onVoipToken: ((String) -> Void)?
    private(set) var voipToken: String?
    private(set) var audioActive = false

    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private var calls: [String: Entry] = [:]
    private var expiry: [String: DispatchWorkItem] = [:]
    private var acceptTimeouts: [String: DispatchWorkItem] = [:]
    /// Terminal ring generations, retained briefly so a delayed duplicate cannot ring a successor's room.
    private var endedInvitations: [String: [String]] = [:]

    private override init() {
        let c = CXProviderConfiguration()
        c.supportsVideo = true
        c.maximumCallGroups = 1
        c.maximumCallsPerCallGroup = 1
        c.supportedHandleTypes = [.generic]
        c.includesCallsInRecents = false
        c.ringtoneSound = "ol_ring_facetime_style.caf" // App/Resources, 20 s PCM; Open Lounge's own synthesized tone
        provider = CXProvider(configuration: c)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// Registers for VoIP pushes (no user prompt).
    func start() {
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
    }

    func hasCall(_ callId: String) -> Bool { calls[callId] != nil }

    // MARK: rings

    private func update(name: String, handle: String, video: Bool) -> CXCallUpdate {
        let u = CXCallUpdate()
        u.remoteHandle = CXHandle(type: .generic, value: handle.isEmpty ? (name.isEmpty ? "Open Lounge" : name) : handle)
        u.localizedCallerName = name.isEmpty ? "Open Lounge" : name
        u.hasVideo = video
        u.supportsHolding = false
        u.supportsGrouping = false
        u.supportsUngrouping = false
        u.supportsDTMF = false
        return u
    }

    private func reportIncoming(callId: String, name: String, handle: String, video: Bool, expiresAtMs: Double,
                                declineToken: String?, invitationId: String? = nil, completion: (() -> Void)? = nil) {
        // One ringing door (t6093u): every ring is a CallKit VIDEO ring into the always-alive A/V room.
        _ = video
        if let invitationId, endedInvitations[callId]?.contains(invitationId) == true {
            // PushKit still requires a report for every VoIP push, but a terminal invitation must never ring again.
            let uuid = OLCallIdentity.uuid(forCallId: callId, invitationId: invitationId)
            provider.reportNewIncomingCall(with: uuid, update: update(name: name, handle: handle, video: true)) { [weak self] _ in
                self?.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
                completion?()
            }
            return
        }
        if var e = calls[callId] {
            if let invitationId, let old = e.invitationId, invitationId != old {
                if expiresAtMs > 0 && e.expiresAtMs > 0 && expiresAtMs <= e.expiresAtMs {
                    // An older generation cannot replace a newer ring for the same durable room.
                    provider.reportNewIncomingCall(with: e.uuid, update: update(name: name, handle: handle, video: true)) { _ in completion?() }
                    return
                }
                guard !e.accepting && !e.answered else {
                    // A successor cannot steal the CXCall while this room is being answered or is active.
                    provider.reportNewIncomingCall(with: e.uuid, update: update(name: name, handle: handle, video: true)) { _ in completion?() }
                    return
                }
                end(callId, reason: .unanswered)
            } else {
                if e.declineToken == nil { e.declineToken = declineToken }
                if expiresAtMs > 0 { e.expiresAtMs = expiresAtMs }
                calls[callId] = e
                armRingExpiry(callId: callId, expiresAtMs: expiresAtMs, invitationId: e.invitationId)
                // Already ringing: report again so iOS counts this push as reported (it rejects the duplicate).
                provider.reportNewIncomingCall(with: e.uuid, update: update(name: name, handle: handle, video: true)) { _ in completion?() }
                return
            }
        }
        let uuid = OLCallIdentity.uuid(forCallId: callId, invitationId: invitationId)
        calls[callId] = Entry(uuid: uuid, incoming: true, invitationId: invitationId,
                              declineToken: declineToken, expiresAtMs: expiresAtMs, name: name, video: true)
        provider.reportNewIncomingCall(with: uuid, update: update(name: name, handle: handle, video: true)) { [weak self] err in
            if err != nil { self?.calls[callId] = nil }
            completion?()
        }
        armRingExpiry(callId: callId, expiresAtMs: expiresAtMs, invitationId: invitationId)
    }

    private func armRingExpiry(callId: String, expiresAtMs: Double, invitationId: String?) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        // expiresAt is absolute server time. Never restart a fresh ring window for a delayed duplicate push.
        let left = expiresAtMs > 0 ? max(0, (expiresAtMs - nowMs) / 1000) : 60
        let w = DispatchWorkItem { [weak self] in self?.endRing(callId, invitationId: invitationId, reason: .unanswered) }
        expiry[callId]?.cancel()
        expiry[callId] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: w)
    }

    /// The caller hung up, someone answered elsewhere, or the ring expired.
    func endRing(_ callId: String, invitationId: String? = nil, reason: CXCallEndedReason) {
        guard let e = calls[callId], !e.answered else { return }
        if let invitationId, e.invitationId != invitationId { return }
        end(callId, reason: reason)
    }

    private func end(_ callId: String, reason: CXCallEndedReason) {
        guard let e = calls.removeValue(forKey: callId) else { return }
        expiry.removeValue(forKey: callId)?.cancel()
        acceptTimeouts.removeValue(forKey: callId)?.cancel()
        e.answerAction?.fail()
        if let invitation = e.invitationId {
            var old = endedInvitations[callId] ?? []
            old.removeAll { $0 == invitation }
            old.append(invitation)
            endedInvitations[callId] = Array(old.suffix(8))
        }
        provider.reportCall(with: e.uuid, endedAt: nil, reason: reason)
        CallController.shared.dismissIncoming(callId: callId)
    }

    // MARK: page call messages

    func onPage(_ m: OLPageCallMessage) {
        switch m {
        case let .incoming(id, name, video, _, expiresAt):
            // Only while the app is not in front: in front, the page rings itself.
            if UIApplication.shared.applicationState != .active || CallController.shared.lockCovering {
                reportIncoming(callId: id, name: name, handle: "", video: true, expiresAtMs: expiresAt ?? 0, declineToken: nil)
            }
        case let .outgoing(id, name, _, _):
            guard calls[id] == nil else { return }
            let uuid = OLCallIdentity.uuid(for: id)
            calls[id] = Entry(uuid: uuid, incoming: false, invitationId: nil, answered: true, expiresAtMs: 0, name: name, video: true)
            let a = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name.isEmpty ? "Open Lounge" : name))
            a.isVideo = true // one ringing door (t6093u): every outgoing ring is the video ring
            a.contactIdentifier = name
            controller.request(CXTransaction(action: a)) { [weak self] err in
                if err != nil { self?.calls[id] = nil }
            }
        case let .answering(id, _, _, _):
            guard var e = calls[id], e.incoming, !e.answered else { return }
            e.answeredInPage = true
            calls[id] = e
            controller.request(CXTransaction(action: CXAnswerCallAction(call: e.uuid))) { _ in }
        case .connected, .ended:
            break // page-sent states are ignored here: CallKit follows the server's lifecycle frames (onLifecycle)
        case .ringtonePrepare:
            // Same rule as Android (CallAudioPolicy.prepareRingtoneOn): only with no live call, reset the session
            // tgcalls left in PlayAndRecord so WebKit plays the page's ringtone as media, not on the call path.
            let s = AVAudioSession.sharedInstance()
            if OLRingtoneSessionPolicy.shouldResetForRingtone(callLive: !calls.isEmpty || NativeMedia.shared.isActive,
                                                              category: s.category.rawValue) {
                do { try s.setCategory(.playback, mode: .default) } catch { NSLog("[OL] ringtonePrepare setCategory failed: \(error)") }
            }
        case .muted, .audioRoute, .ringbackStop:
            break // in-call UI cues, and ringback is the page's own <audio> (no native ringback on iOS)
        }
    }

    // MARK: server lifecycle frames (BaoTime binding)

    /// The CallKit banner from the same server frame that moves CallScreen and MiniBar (OLCallFlow.callKit).
    func onLifecycle(callId: String, _ l: OLCallLifecycle) {
        guard let e = calls[callId] else { return }
        switch OLCallFlow.callKit(for: l) {
        case .none:
            break
        case .startedConnecting:
            if e.incoming {
                acknowledgeAnswer(callId: callId)
            } else {
                provider.reportOutgoingCall(with: e.uuid, startedConnectingAt: Date())
            }
        case .connected:
            if e.incoming {
                acknowledgeAnswer(callId: callId)
            } else {
                provider.reportOutgoingCall(with: e.uuid, connectedAt: Date())
            }
        case let .ended(r):
            switch r {
            case .failed: end(callId, reason: .failed)
            case .unanswered: end(callId, reason: .unanswered)
            case .remoteEnded: end(callId, reason: .remoteEnded)
            }
        }
    }

    /// Server Answering/JoiningUrl/Connecting/InRoom is the Accept acknowledgement. The user's tap is not.
    private func acknowledgeAnswer(callId: String) {
        guard var e = calls[callId], e.incoming, !e.answered else { return }
        acceptTimeouts.removeValue(forKey: callId)?.cancel()
        e.answered = true
        e.accepting = false
        let action = e.answerAction
        e.answerAction = nil
        calls[callId] = e
        if let action {
            NativeMedia.configureSessionForCallKit() // category before fulfill, or didActivate never arrives
            action.fulfill()
        }
    }

    private func acceptTimedOut(_ callId: String) {
        guard let e = calls[callId], e.accepting, !e.answered else { return }
        CallController.shared.answering(callId: callId, name: e.name, video: e.video)
        CallController.shared.showNetworkFailure("Accept timed out. Check your connection and try again.")
        host?.emitNativeMedia(["state": "failed", "callId": callId, "reason": "accept-timeout"])
        host?.dispatchNativeCall(["type": "call:hangup", "callId": callId, "reason": "accept-timeout"])
        if NativeMedia.shared.callId == callId { NativeMedia.shared.close() }
        end(callId, reason: .failed)
    }

    // MARK: in-app incoming card (shown over App Lock)

    func answerFromApp(_ callId: String) {
        guard let e = calls[callId] else { return host?.answerInPage(callId: callId) ?? () }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: e.uuid))) { _ in }
    }

    func declineFromApp(_ callId: String) {
        guard let e = calls[callId] else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: e.uuid))) { _ in }
    }

    /// The app's call screen ended the call.
    func endFromApp(_ callId: String) {
        guard let e = calls[callId] else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: e.uuid))) { [weak self] err in
            if err != nil { self?.end(callId, reason: .remoteEnded) }
        }
    }

    private func callId(for uuid: UUID) -> String? { calls.first { $0.value.uuid == uuid }?.key }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        calls.values.forEach { $0.answerAction?.fail() }
        calls.removeAll()
        expiry.values.forEach { $0.cancel() }
        expiry.removeAll()
        acceptTimeouts.values.forEach { $0.cancel() }
        acceptTimeouts.removeAll()
        NativeMedia.shared.close()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        NativeMedia.configureSessionForCallKit() // category before fulfill, or didActivate never arrives
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let id = callId(for: action.callUUID), var e = calls[id], !e.answered else { return action.fail() }
        guard !e.accepting else { return } // the original action owns the bounded Accept transaction
        e.accepting = true
        e.answerAction = action
        calls[id] = e
        expiry.removeValue(forKey: id)?.cancel()
        host?.unlockForCall()
        CallController.shared.dismissIncoming(callId: id)
        if !e.answeredInPage {
            CallController.shared.answering(callId: id, name: e.name, video: e.video)
            host?.answerInPage(callId: id)
        }
        let timeout = DispatchWorkItem { [weak self] in self?.acceptTimedOut(id) }
        acceptTimeouts[id] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.acceptTimeout, execute: timeout)
        // Do not fulfill here. acknowledgeAnswer fulfills only after the server accepts the invitation.
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let id = callId(for: action.callUUID), let e = calls.removeValue(forKey: id) else { return action.fulfill() }
        expiry.removeValue(forKey: id)?.cancel()
        acceptTimeouts.removeValue(forKey: id)?.cancel()
        e.answerAction?.fail()
        if let invitation = e.invitationId {
            var old = endedInvitations[id] ?? []
            old.removeAll { $0 == invitation }; old.append(invitation)
            endedInvitations[id] = Array(old.suffix(8))
        }
        CallController.shared.dismissIncoming(callId: id)
        if e.incoming && !e.answered {
            if let h = host {
                CallAPI.decline(origin: h.origin, callId: id, declineToken: e.declineToken, access: h.accessToken)
            }
        } else {
            host?.dispatchNativeCall(["type": "call:hangup", "callId": id])
            if NativeMedia.shared.callId == id { NativeMedia.shared.close() }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        NativeMedia.shared.setMuted(action.isMuted)
        host?.dispatchNativeCall(["type": "call:mute", "muted": action.isMuted])
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { action.fail() }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        NativeMedia.shared.callKitDidActivate(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActive = false
        // The native engine owns hang-up authority on ring calls and tells the call server itself (no page mediation).
        NativeMedia.shared.callKitDidDeactivate(audioSession)
    }

    // MARK: PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP, let t = OLCallIdentity.voipTokenHex(credentials.token) else { return }
        voipToken = t
        onVoipToken?(t)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else { return completion() }
        guard let ring = OLIncomingRing.parse(payload.dictionaryPayload) else {
            // iOS requires a CallKit report for every VoIP push: report and end a placeholder.
            let uuid = UUID()
            provider.reportNewIncomingCall(with: uuid, update: update(name: "Open Lounge", handle: "", video: false)) { [weak self] _ in
                self?.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                completion()
            }
            return
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        reportIncoming(callId: ring.callId, name: ring.callerName, handle: ring.callerId, video: ring.video,
                       expiresAtMs: ring.expiresAt, declineToken: ring.declineToken,
                       invitationId: ring.invitationId) { [weak self] in
            if ring.expired(nowMs: nowMs), let self {
                // Legacy payloads have no generation: their late expiry must not kill an identified successor.
                if ring.invitationId != nil || self.calls[ring.callId]?.invitationId == nil {
                    self.endRing(ring.callId, invitationId: ring.invitationId, reason: .unanswered)
                }
            }
            completion()
        }
        CallController.shared.ringing(callId: ring.callId, name: ring.callerName, photo: ring.callerPhoto, video: true)
    }
}
