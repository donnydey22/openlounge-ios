// CallController — the one state machine behind the iOS three-banner stack: the full CallScreen, the green
// MiniBar (in the app) and CallKit (outside the app). BaoTime binding (Donny, Nov 19 2026): the call server's
// seven-state lifecycle frames (OLTgcallsEngine .lifecycle, and the page's call:lifecycle relay) are the ONLY input
// that moves these surfaces, mapped by OLCallFlow exactly like Android NativeCallFlow. Page call:* messages carry
// metadata only (name, photo, video, mute, route). Buttons act through the page: mute -> "call:mute",
// end -> "call:hangup", Call again -> "call:retry"; the screen then waits for the server's next frame.
import Combine
import Foundation
import OLShellCore
import UIKit
import OLCallCore

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
    /// The other person's mic is off (their tgcalls audio state): web mute badge (t6106u).
    @Published var remoteMuted = false
    @Published var remoteVideoView: UIView?
    @Published var localVideoView: UIView?
    @Published private(set) var facingFront = true
    @Published private(set) var minimized = false
    /// First-design network-failure chrome (ended overlay + the connect-on-this-network copy). Stays until Close.
    @Published private(set) var failed = false
    @Published private(set) var failedText = ""
    /// This phone's media leg reached the Pion server (tgcalls Established): enables Speaker / Mute. Not a state.
    @Published private(set) var engineUp = false
    /// Server-owned call lifecycle (olcall states.go). Read-only mirror: set only by observeLifecycle from the
    /// server's snapshot (seq-ordered), never computed or advanced here.
    @Published private(set) var lifecycle: OLCallLifecycle?
    /// The surface for that snapshot (OLCallFlow); nil until the first server frame (status stays blank).
    @Published private(set) var screen: OLCallFlow.Screen?
    /// Full call UI (row, timer, video, minimize) only while the server says in_room.
    var live: Bool { screen == .active }
    /// Latest frame per call, so a frame that lands before call:outgoing / answering is applied on begin.
    private var latest: [String: OLCallLifecycle] = [:]

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
            begin(id, name: name, photo: photo.flatMap(Self.photoURL), video: video)
        case let .answering(id, name, video, photo):
            let n = names[id]
            begin(id, name: name.isEmpty ? (n?.0 ?? peerName) : name,
                  photo: photo.flatMap(Self.photoURL) ?? n?.1,
                  video: video || (n?.2 ?? false))
        case .connected, .ended:
            break // page-sent states are ignored here: only the server's lifecycle frames move the call surfaces
        case let .muted(m):
            muted = m
        case let .audioRoute(speaker):
            speakerOn = speaker
        case .ringbackStop, .ringtonePrepare:
            break // tone cues for the page's own ringer; the call screen has no state for them
        }
    }

    func ringing(callId id: String, name: String, photo: String?, video: Bool) {
        names[id] = (name, photo.flatMap(Self.photoURL), video)
    }

    func answering(callId id: String, name: String, video: Bool, photo: String? = nil) {
        let n = names[id]
        begin(id, name: name.isEmpty ? (n?.0 ?? peerName) : name,
              photo: photo.flatMap(Self.photoURL) ?? n?.1, video: video)
    }

    func engineStarted(callId id: String, video: Bool) {
        if !visible || callId != id { begin(id, name: names[id]?.0 ?? peerName, photo: names[id]?.1, video: video) }
        cameraOn = video
        speakerOn = video
    }

    /// This phone's media leg reached the server (tgcalls Established). Not an answer and not first inbound media.
    func mediaConnected(callId id: String) { if id == callId { engineUp = true; tick() } }

    /// One path (t6093u): the page marks a link join ("link": true on call:answering). A link never rings; alone in it
    /// with this phone's leg up, the status reads "Waiting for <first name>…".
    @Published private(set) var link = false
    private var linkIds: Set<String> = []
    func markLink(callId id: String, fromJSON raw: String) {
        guard let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if o["link"] as? Bool == true { linkIds.insert(id); if id == callId { link = true; tick() } }
    }

    /// The single input of the three-banner stack: the server's lifecycle snapshot (engine leg socket, or the
    /// page's call:lifecycle relay of the backend call:state). Seq-ordered; stale and duplicate frames are dropped.
    func observeLifecycle(callId id: String, _ l: OLCallLifecycle) {
        guard !id.isEmpty, OLCallLifecycle.newer(latest[id], l) else { return }
        latest[id] = l
        CallCenter.shared.onLifecycle(callId: id, l) // CallKit banner, same frame
        if let d = OLCallFlow.pageDetail(callId: id, l) { host?.dispatchNativeCall(d) } // seven states back to the page
        if l.state == .terminal, id == incomingCallId { incomingVisible = false }
        guard visible, id == callId else { return } // applied on begin()
        apply(l)
    }

    private func apply(_ l: OLCallLifecycle) {
        lifecycle = l
        let s = OLCallFlow.screen(for: l)
        screen = s
        switch s {
        case .none: break
        case .ringing: setPhase(.calling)
        case .answering, .joining, .connecting: setPhase(.connecting)
        case .active: setPhase(.active)
        case .failed: showNetworkFailure(CallPresence.failMsg)
        case .ended: showEndCard(l.reason)
        }
    }

    /// Mid-call media is reconnecting (this phone's engine, or the server `peer` frame for the other party).
    /// The status line shows "Reconnecting…" instead of the timer until it is back.
    private var reconnecting = false
    func setReconnecting(callId id: String, on: Bool) {
        guard id == callId, reconnecting != on else { return }
        reconnecting = on
        tick()
    }

    func engineEnded(callId id: String) {
        guard id == callId else { return }
        engineUp = false
        remoteVideoView = nil
        localVideoView = nil
        remoteVideoOn = false
        remoteMuted = false
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

    /// End call: asks the server through the page, then waits for its terminal frame (the screen never ends itself).
    func end() {
        let id = callId
        host?.dispatchNativeCall(["type": "call:hangup", "callId": id])
        NativeMedia.shared.close()
        CallCenter.shared.endFromApp(id)
    }

    /// Call again on the failure screen (same message as Android NativeCallScreen's retry row).
    func retry() {
        let id = callId
        finish()
        host?.dispatchNativeCall(["type": "call:retry", "callId": id])
    }

    /// Terminal (not failed): the end card (avatar, name, reason text, or "Call ended · m:ss" after in_room), for
    /// web engine.ts:93 ENDED_LINGER_MS (1.8 s); same as Android NativeCallScreen.showEndCard.
    @Published private(set) var endedCard = false
    private var endedWork: DispatchWorkItem?
    private func showEndCard(_ reason: OLCallLifecycle.Reason?) {
        guard visible, !failed else { finish(); return }
        let text = OLCallFlow.endedText(reason)
        timer?.invalidate()
        timer = nil
        minimized = false
        engineEnded(callId: callId)
        endedCard = true
        phase = .ended
        if let at = activeAt, reason == .completed || reason == .disconnected {
            statusText = text + " · " + OLCallFlow.timer(Int(Date().timeIntervalSince(at)))
        } else {
            statusText = text
        }
        let w = DispatchWorkItem { [weak self] in if self?.endedCard == true { self?.finish() } }
        endedWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    func dismissEndCard() { finish() }

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

    private func begin(_ id: String, name: String, photo: URL?, video v: Bool) {
        reconnecting = false
        if callId != id {
            activeAt = nil
            lifecycle = nil // new call: no server snapshot yet
            screen = nil
            engineUp = false
            muted = false
            remoteVideoOn = false
            remoteMuted = false
            remoteVideoView = nil
            localVideoView = nil
            facingFront = true
            minimized = false
            failed = false
            failedText = ""
            endedCard = false
            endedWork?.cancel()
            phase = .calling
        }
        callId = id
        link = linkIds.contains(id)
        peerName = name.isEmpty ? "Open Lounge" : name
        peerPhoto = photo
        video = v
        visible = true
        incomingVisible = false
        startPresencePeek()
        if let l = latest[id] { apply(l) } else { tick() } // blank status until the server's first frame
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
        if failed || endedCard { return }
        if reconnecting && live { statusText = "Reconnecting…"; return }
        statusText = live ? OLCallFlow.timer(secs) : OLCallFlow.statusText(screen, reason: nil, waitingLink: link && engineUp, peer: peerName)
    }

    private func finish() {
        reconnecting = false
        endedWork?.cancel()
        endedWork = nil
        endedCard = false
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
        // The page renders the server's call info (current profile) a moment after it posts call:outgoing: look again
        // right away instead of showing the chat header's snapshot / initials until the next 2 s tick.
        for d in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, self.presenceTimer != nil else { return }
                self.peekPresence()
            }
        }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.peekPresence()
        }
    }

    /// Presence, display name and profile photo follow the page call screen, i.e. the person's current profile
    /// (OLCallScreenIdentity), from the "Calling…" card through the call. Read-only page peeks; never touches the call.
    private func peekPresence() {
        host?.peekCallPresence { [weak self] raw in
            DispatchQueue.main.async { self?.applyPeek(raw) }
        }
        host?.peekCallName { [weak self] raw in
            DispatchQueue.main.async {
                guard let self, self.visible || self.incomingVisible else { return }
                if let n = OLCallScreenIdentity.name(peeked: raw, current: self.peerName) { self.peerName = n }
            }
        }
        host?.peekCallPhoto { [weak self] raw in
            DispatchQueue.main.async {
                guard let self, self.visible || self.incomingVisible else { return }
                if let u = OLCallScreenIdentity.photo(peeked: raw, current: self.peerPhoto) { self.peerPhoto = u }
            }
        }
    }

    static func photoURL(_ s: String) -> URL? {
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        return URL(string: s)
    }
}
