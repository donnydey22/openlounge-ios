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
    @Published private(set) var video = false
    @Published private(set) var phase: OLCallPhase = .calling
    @Published private(set) var statusText = ""
    @Published var muted = false
    @Published private(set) var speakerOn = false
    @Published var cameraOn = false
    @Published var remoteVideoOn = false
    @Published var remoteVideoView: UIView?
    @Published var localVideoView: UIView?

    // incoming card (over App Lock only; otherwise CallKit or the page ring)
    @Published private(set) var incomingVisible = false
    @Published var lockCovering = false

    var canToggleVideo: Bool { NativeMedia.shared.callId == callId && (phase == .connecting || phase == .active) }

    private var activeAt: Date?
    private var timer: Timer?
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
        NativeMedia.shared.handle(["op": .string("camera"), "on": .bool(on), "facing": .string("user")]) { _, _, _ in }
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
    }

    private func begin(_ id: String, name: String, photo: URL?, video v: Bool, phase p: OLCallPhase) {
        if callId != id {
            activeAt = nil
            muted = false
            remoteVideoOn = false
            remoteVideoView = nil
            localVideoView = nil
        }
        callId = id
        peerName = name.isEmpty ? "Open Lounge" : name
        peerPhoto = photo
        video = v
        visible = true
        incomingVisible = false
        setPhase(p)
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
        visible = false
        activeAt = nil
        phase = .ended
        engineEnded(callId: callId)
    }

    static func photoURL(_ s: String) -> URL? {
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        return URL(string: s)
    }
}
