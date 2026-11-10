// CallController — one Open Lounge call on this phone, from tap to hang-up (the app-side twin of
// Android's app-side call class). One path:
//   permission gate -> backend call control (start / accept -> CallMedia) -> OLTgcallsEngine
// A refused permission ends the attempt silently: no screen, no message, no second prompt.
import Foundation
import OLCall
import OLCallCore
import SwiftUI
import UIKit

@MainActor
final class CallController: ObservableObject {
    enum Phase: Equatable { case idle, incoming, waiting, connecting, active, ended }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName = ""
    @Published private(set) var peerPhoto: URL?
    @Published private(set) var video = false
    @Published private(set) var muted = false
    @Published private(set) var speakerOn = false
    @Published private(set) var cameraOn = false
    @Published private(set) var remoteVideoOn = false
    @Published private(set) var remoteVideoView: UIView?
    @Published private(set) var localVideoView: UIView?
    @Published private(set) var activeSince: Date?
    @Published private var tick = Date()

    private let control: OLCallControl
    private let gate: OLCallPermissionGate
    private var engine: OLTgcallsEngine?
    private var callId = ""
    private var timer: Timer?

    init(control: OLCallControl, permissions: OLPermissionProvider) {
        self.control = control
        gate = OLCallPermissionGate(provider: permissions)
    }

    var statusText: String {
        switch phase {
        case .waiting: return "Calling…"
        case .connecting: return "Connecting…"
        case .active:
            let s = max(0, Int(tick.timeIntervalSince(activeSince ?? tick)))
            return String(format: "%d:%02d", s / 60, s % 60)
        case .ended: return "Call ended"
        case .idle, .incoming: return ""
        }
    }

    var canToggleVideo: Bool { engine != nil && (phase == .waiting || phase == .connecting || phase == .active) }

    // MARK: outgoing

    func startCall(peerId: String, name: String, photo: URL?, video: Bool) {
        guard phase == .idle else { return }
        gate.authorize(video ? .videoCall : .audioCall) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, granted, self.phase == .idle else { return }
                self.present(name: name, photo: photo, video: video, phase: .waiting)
                self.control.start(peerId: peerId, video: video) { result in
                    DispatchQueue.main.async { self.join(result) }
                }
            }
        }
    }

    // MARK: incoming

    func incoming(callId: String, name: String, photo: URL?, video: Bool) {
        guard phase == .idle else { return }
        self.callId = callId
        present(name: name, photo: photo, video: video, phase: .incoming)
    }

    func accept() {
        guard phase == .incoming else { return }
        let id = callId
        gate.authorize(video ? .videoCall : .audioCall) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.phase == .incoming else { return }
                guard granted else {
                    self.control.decline(callId: id)
                    self.reset()
                    return
                }
                self.phase = .connecting
                self.control.accept(callId: id) { result in
                    DispatchQueue.main.async { self.join(result) }
                }
            }
        }
    }

    func decline() {
        guard phase == .incoming else { return }
        control.decline(callId: callId)
        reset()
    }

    // MARK: in call

    func toggleMute() {
        muted.toggle()
        engine?.setMuted(muted)
    }

    func toggleSpeaker() {
        speakerOn.toggle()
        engine?.setSpeaker(speakerOn)
    }

    func toggleVideo() {
        guard let engine else { return }
        if cameraOn {
            cameraOn = false
            engine.setVideoEnabled(false)
            return
        }
        gate.authorize(.videoToggle) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, granted, let e = self.engine, e === engine else { return }
                self.cameraOn = true
                e.setVideoEnabled(true)
            }
        }
    }

    func end() {
        if let engine {
            engine.hangup()
        } else if !callId.isEmpty {
            control.hangup(callId: callId)
            finish()
        } else {
            finish()
        }
    }

    // MARK: engine

    private func join(_ result: Result<OLCallMedia, OLCallControlError>) {
        guard phase == .waiting || phase == .connecting else { return }
        guard case let .success(media) = result else { return finish() }
        if !media.callId.isEmpty { callId = media.callId }
        do {
            let e = try OLTgcallsEngine(media: media, video: video, usesCallKit: false)
            engine = e
            e.onEvent = { [weak self] ev in self?.onEngine(ev) }
            if muted { e.setMuted(true) }
            e.start()
        } catch {
            NSLog("olcall engine create failed: %@", String(describing: error))
            control.hangup(callId: callId)
            finish()
        }
    }

    private func onEngine(_ ev: OLTgcallsEngine.Event) {
        switch ev {
        case let .state(s, remoteVideo, _):
            remoteVideoOn = remoteVideo
            if s == .connected && phase != .active {
                phase = .active
                activeSince = Date()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick = Date() }
                }
            }
        case let .remoteVideoView(v): remoteVideoView = v
        case let .localVideoView(v): localVideoView = v
        case .ended: finish()
        case .joined, .audio, .audioFailed, .route: break
        }
    }

    // MARK: helpers

    private func present(name: String, photo: URL?, video: Bool, phase: Phase) {
        peerName = name
        peerPhoto = photo
        self.video = video
        speakerOn = video
        cameraOn = video
        muted = false
        self.phase = phase
    }

    private func finish() {
        guard phase != .idle, phase != .ended else { return }
        timer?.invalidate(); timer = nil
        engine = nil
        phase = .ended
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.reset() }
    }

    private func reset() {
        timer?.invalidate(); timer = nil
        engine = nil
        callId = ""
        phase = .idle
        remoteVideoOn = false
        remoteVideoView = nil
        localVideoView = nil
        activeSince = nil
        cameraOn = false
        muted = false
    }
}
