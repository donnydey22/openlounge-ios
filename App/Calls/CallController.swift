// CallController — state of the app's own call screens (CallScreen, IncomingCallScreen).
// It follows the page's call messages (call:outgoing / answering / connected / ended), the
// engine (connected, video views) and CallKit (rings). Buttons act through the page, so the page,
// the server and the media stay in step: mute -> "call:mute", end -> "call:hangup".
import Combine
import Foundation
import OLShellCore
import UIKit

final class CallController: ObservableObject {
    static let shared = CallController()

    weak var host: ShellHost?

    // call screen
    @Published private(set) var visible = false
    @Published private(set) var callId = ""
    @Published private(set) var peerName = ""
    @Published private(set) var peerPhoto: URL?
    /// "online" / "away", or nil when offline or unknown (101e00a Avatar hides the dot).
    @Published private(set) var peerPresence: String?
    @Published private(set) var video = false
    @Published private(set) var phase: OLCallPhase = .calling
    @Published private(set) var statusText = ""
    @Published var muted = false
    @Published private(set) var speakerOn = false
    @Published var cameraOn = false
    @Published var remoteVideoOn = false
    @Published var remoteVideoView: UIView?
    @Published var localVideoView: UIView?
    @Published private(set) var facingFront = true
    @Published private(set) var minimized = false
    /// First-design network-failure chrome (ended overlay + the connect-on-this-network copy). Stays until Close.
    @Published private(set) var failed = false
    @Published private(set) var failedText = ""

    // incoming card (over App Lock only; otherwise CallKit or the page ring)
    @Published private(set) var incomingVisible = false
    @Published var lockCovering = false

    var canToggleVideo: Bool { NativeMedia.shared.callId == callId && (phase == .connecting || phase == .active) }

    private var activeAt: Date?
    private var timer: Timer?
    private var presenceTimer: Timer?
    private var names: [String: (String, URL?, Bool)] = [:]

    // MARK: inputs

    func onPage(_ m: OLPageCallMessage) {
        switch m {
        case let .incoming(id, name, video, photo, _):
            names[id] = (name, photo.flatMap(Self.photoURL), video)
            if lockCovering { show(incoming: id) }
        case let .outgoing(id, name, video, photo):
            begin(id, name: name, photo: photo.flatMap(Self.photoURL), video: video, phase: .calling)
        case let .answering(id, video):
            let n = names[id]
            begin(id, name: n?.0 ?? peerName, photo: n?.1, video: video || (n?.2 ?? false), phase: .connecting)
        case let .connected(id):
            if id.isEmpty || id == callId { setPhase(.active) }
        case let .ended(id):
            if id.isEmpty || id == callId { finish() }
            if id.isEmpty || id == callId { incomingVisible = false }
        case let .muted(m):
            muted = m
        case let .audioRoute(speaker):
            speakerOn = speaker
        default:
            break
        }
    }

    func ringing(callId id: String, name: String, photo: String?, video: Bool) {
        names[id] = (name, photo.flatMap(Self.photoURL), video)
    }

    func answering(callId id: String, name: String, video: Bool) {
        let n = names[id]
        begin(id, name: n?.0 ?? name, photo: n?.1, video: video, phase: .connecting)
    }

    func engineStarted(callId id: String, video: Bool) {
        if !visible || callId != id { begin(id, name: names[id]?.0 ?? peerName, photo: names[id]?.1, video: video, phase: phase) }
        cameraOn = video
        speakerOn = video
    }

    func mediaConnected(callId id: String) { if id == callId { setPhase(.active) } }

    func engineEnded(callId id: String) {
        guard id == callId else { return }
        remoteVideoView = nil
        localVideoView = nil
        remoteVideoOn = false
        cameraOn = false
    }

    func dismissIncoming(callId id: String) { if incomingCallId == id { incomingVisible = false } }

    // MARK: buttons

    func toggleMute() {
        let m = !muted
        NativeMedia.shared.setMuted(m)
        host?.dispatchNativeCall(["type": "call:mute", "muted": m])
    }

    func toggleSpeaker() {
        speakerOn.toggle()
        NativeMedia.shared.setSpeaker(speakerOn)
    }

    func toggleVideo() {
        let on = !cameraOn
        NativeMedia.shared.handle(["op": .string("camera"), "on": .bool(on), "facing": .string(facingFront ? "user" : "environment")]) { _, _, _ in }
    }

    /// Flip the local camera. Uses the existing NativeMedia camera op; does not change the engine path.
    func flip() {
        guard cameraOn else { return }
        facingFront.toggle()
        NativeMedia.shared.handle(["op": .string("camera"), "on": .bool(true), "facing": .string(facingFront ? "user" : "environment")]) { _, _, _ in }
    }

    func setMinimized(_ on: Bool) {
        // UI-only: the engine, media and logging stay running.
        minimized = on
    }

    func end() {
        let id = callId
        host?.dispatchNativeCall(["type": "call:hangup", "callId": id])
        NativeMedia.shared.close()
        CallCenter.shared.endFromApp(id)
        finish()
    }

    private(set) var incomingCallId = ""

    func accept() {
        incomingVisible = false
        host?.unlockForCall()
        CallCenter.shared.answerFromApp(incomingCallId)
    }

    func decline() {
        incomingVisible = false
        CallCenter.shared.declineFromApp(incomingCallId)
        host?.dispatchNativeCall(["type": "call:decline", "callId": incomingCallId])
    }

    // MARK: state

    private func show(incoming id: String) {
        incomingCallId = id
        let n = names[id]
        if !visible { peerName = n?.0 ?? ""; peerPhoto = n?.1; video = n?.2 ?? false }
        incomingVisible = true
        startPresencePeek()
    }

    private func begin(_ id: String, name: String, photo: URL?, video v: Bool, phase p: OLCallPhase) {
        if callId != id {
            activeAt = nil
            muted = false
            remoteVideoOn = false
            remoteVideoView = nil
            localVideoView = nil
            facingFront = true
            minimized = false
            failed = false
            failedText = ""
        }
        callId = id
        peerName = name.isEmpty ? "Open Lounge" : name
        peerPhoto = photo
        video = v
        visible = true
        incomingVisible = false
        setPhase(p)
        startPresencePeek()
    }

    private func setPhase(_ p: OLCallPhase) {
        phase = p
        if p == .active, activeAt == nil {
            activeAt = Date()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
        tick()
    }

    private func tick() {
        let secs = activeAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        statusText = phase.status(seconds: secs)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        visible = false
        minimized = false
        failed = false
        failedText = ""
        activeAt = nil
        peerPresence = nil
        phase = .ended
        engineEnded(callId: callId)
    }

    /// Show the first-design failure screen instead of immediately dismissing the overlay.
    func showNetworkFailure(_ text: String) {
        incomingVisible = false
        failed = true
        failedText = text
        phase = .ended
        statusText = text
        visible = true
        minimized = false
        remoteVideoOn = false
        timer?.invalidate()
        timer = nil
    }

    func dismissFailed() {
        finish()
    }

    func applyPresence(_ raw: String?) {
        if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            peerPresence = CallPresence.of(raw)
        }
    }

    func setPresenceFromMessage(_ raw: String?) {
        peerPresence = CallPresence.of(raw)
    }

    func applyPeek(_ raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return } // page had no data-presence node; keep last known
        peerPresence = CallPresence.of(t)
    }

    private func startPresencePeek() {
        presenceTimer?.invalidate()
        peekPresence()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.peekPresence()
        }
    }

    private func peekPresence() {
        host?.peekCallPresence { [weak self] raw in
            DispatchQueue.main.async { self?.applyPeek(raw) }
        }
        if peerPhoto == nil {
            host?.peekCallPhoto { [weak self] raw in
                DispatchQueue.main.async {
                    guard let self, self.peerPhoto == nil else { return }
                    let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if let u = Self.photoURL(t) { self.peerPhoto = u }
                }
            }
        }
    }

    static func photoURL(_ s: String) -> URL? {
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        return URL(string: s)
    }
}
