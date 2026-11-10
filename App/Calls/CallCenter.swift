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
import PushKit
import UIKit

final class CallCenter: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
    static let shared = CallCenter()

    private struct Entry {
        let uuid: UUID
        let incoming: Bool
        var answered = false
        var answeredInPage = false
        var declineToken: String?
        var name: String
        var video: Bool
    }

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

    private override init() {
        let c = CXProviderConfiguration()
        c.supportsVideo = true
        c.maximumCallGroups = 1
        c.maximumCallsPerCallGroup = 1
        c.supportedHandleTypes = [.generic]
        c.includesCallsInRecents = false
        c.ringtoneSound = "openlounge-incoming.caf"
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
                                declineToken: String?, completion: (() -> Void)? = nil) {
        if var e = calls[callId] {
            if e.declineToken == nil { e.declineToken = declineToken; calls[callId] = e }
            // Already ringing: report again so iOS counts this push as reported (it rejects the duplicate).
            provider.reportNewIncomingCall(with: e.uuid, update: update(name: name, handle: handle, video: video)) { _ in completion?() }
            return
        }
        let uuid = OLCallIdentity.uuid(for: callId)
        calls[callId] = Entry(uuid: uuid, incoming: true, declineToken: declineToken, name: name, video: video)
        provider.reportNewIncomingCall(with: uuid, update: update(name: name, handle: handle, video: video)) { [weak self] err in
            if err != nil { self?.calls[callId] = nil }
            completion?()
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let left = expiresAtMs > 0 ? max(0, (expiresAtMs - nowMs) / 1000) : 60
        let w = DispatchWorkItem { [weak self] in self?.endRing(callId, reason: .unanswered) }
        expiry[callId]?.cancel()
        expiry[callId] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: w)
    }

    /// The caller hung up, someone answered elsewhere, or the ring expired.
    func endRing(_ callId: String, reason: CXCallEndedReason) {
        guard let e = calls[callId], !e.answered else { return }
        end(callId, reason: reason)
    }

    private func end(_ callId: String, reason: CXCallEndedReason) {
        guard let e = calls.removeValue(forKey: callId) else { return }
        expiry.removeValue(forKey: callId)?.cancel()
        provider.reportCall(with: e.uuid, endedAt: nil, reason: reason)
        CallController.shared.dismissIncoming(callId: callId)
    }

    // MARK: page call messages

    func onPage(_ m: OLPageCallMessage) {
        switch m {
        case let .incoming(id, name, video, _, expiresAt):
            // Only while the app is not in front: in front, the page rings itself.
            if UIApplication.shared.applicationState != .active || CallController.shared.lockCovering {
                reportIncoming(callId: id, name: name, handle: "", video: video, expiresAtMs: expiresAt ?? 0, declineToken: nil)
            }
        case let .outgoing(id, name, video, _):
            guard calls[id] == nil else { return }
            let uuid = OLCallIdentity.uuid(for: id)
            calls[id] = Entry(uuid: uuid, incoming: false, answered: true, name: name, video: video)
            let a = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name.isEmpty ? "Open Lounge" : name))
            a.isVideo = video
            a.contactIdentifier = name
            controller.request(CXTransaction(action: a)) { [weak self] err in
                if err != nil { self?.calls[id] = nil }
            }
        case let .answering(id, _):
            guard var e = calls[id], e.incoming, !e.answered else { return }
            e.answeredInPage = true
            calls[id] = e
            controller.request(CXTransaction(action: CXAnswerCallAction(call: e.uuid))) { _ in }
        case let .connected(id):
            let key = id.isEmpty ? calls.first(where: { !$0.value.incoming })?.key : id
            if let key, let e = calls[key], !e.incoming { provider.reportOutgoingCall(with: e.uuid, connectedAt: Date()) }
        case let .ended(id):
            let keys = id.isEmpty ? Array(calls.keys) : [id]
            keys.forEach { end($0, reason: .remoteEnded) }
        default:
            break
        }
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
        calls.removeAll()
        expiry.values.forEach { $0.cancel() }
        expiry.removeAll()
        NativeMedia.shared.close()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let id = callId(for: action.callUUID), var e = calls[id] else { return action.fail() }
        e.answered = true
        calls[id] = e
        expiry.removeValue(forKey: id)?.cancel()
        host?.unlockForCall()
        CallController.shared.dismissIncoming(callId: id)
        if !e.answeredInPage {
            CallController.shared.answering(callId: id, name: e.name, video: e.video)
            host?.answerInPage(callId: id)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let id = callId(for: action.callUUID), let e = calls.removeValue(forKey: id) else { return action.fulfill() }
        expiry.removeValue(forKey: id)?.cancel()
        CallController.shared.dismissIncoming(callId: id)
        if e.incoming && !e.answered {
            if let h = host {
                CallAPI.decline(origin: h.origin, callId: id, declineToken: e.declineToken, access: h.accessToken)
                h.dispatchNativeCall(["type": "call:decline", "callId": id])
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
                       expiresAtMs: ring.expiresAt, declineToken: ring.declineToken) { [weak self] in
            if ring.expired(nowMs: nowMs) { self?.endRing(ring.callId, reason: .unanswered) }
            completion()
        }
        CallController.shared.ringing(callId: ring.callId, name: ring.callerName, photo: ring.callerPhoto, video: ring.video)
    }
}
