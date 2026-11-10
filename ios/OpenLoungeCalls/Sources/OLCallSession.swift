// OLCallSession — UI-state adapter between the EXISTING Open Lounge call screen
// and the thin tgcalls wrapper (ios/OLTgcallsSwift: OLCall = OLCallAudioDevice +
// OLSignalingRelay + OLTgcallsCall over Telegram-iOS's TgVoipWebrtc).
//
// It renders nothing: the original OL call UI (avatar in the squircle frame,
// name, timer, controls) is driven by `onUiState`, and the video views are
// handed to that screen to place inside its existing frames.
//
// Since 2026-11-09 the engine, audio-session and WebSocket code live only in
// OLTgcallsSwift (this file used to contain its own copy). The Expo pod compiles
// those sources into the same module (install-into-ol-app.sh copies them), so
// no `import OLTgcalls` is needed there; SwiftPM consumers get it via the import.
//
// STATUS: NOT COMPILED (the build host is Linux).
import AVFAudio
import Foundation
import UIKit
#if canImport(OLTgcalls)
import OLTgcalls
#endif

public final class OLCallSession: NSObject {
    public enum Phase: String { case connecting, inCall, reconnecting, ended }

    public struct Peer {
        public let userId: String
        public let displayName: String
        public let avatarUrl: String?
        public init(userId: String, displayName: String, avatarUrl: String?) {
            self.userId = userId; self.displayName = displayName; self.avatarUrl = avatarUrl
        }
    }

    /// Everything the existing call screen needs to draw itself.
    public struct UiState {
        public var phase: Phase = .connecting
        public var isVideoCall: Bool
        public var elapsedSec: Int = 0
        public var muted = false
        public var cameraOn: Bool
        public var frontCamera = true
        public var speakerOn: Bool
        public var remoteMuted = false
        public var remoteVideoOn = false
        public var endReason: String?
        /// Verbatim AVAudioSession failure ("domain:code:first") when the microphone could not be opened.
        public var audioError: String?

        public func asDictionary(peer: Peer) -> [String: Any] {
            var d: [String: Any] = [
                "phase": phase.rawValue, "isVideoCall": isVideoCall, "elapsedSec": elapsedSec, "muted": muted,
                "cameraOn": cameraOn, "frontCamera": frontCamera, "speakerOn": speakerOn,
                "remoteMuted": remoteMuted, "remoteVideoOn": remoteVideoOn,
                "peer": ["userId": peer.userId, "displayName": peer.displayName, "avatarUrl": peer.avatarUrl as Any],
            ]
            if let endReason { d["endReason"] = endReason }
            if let audioError { d["audioError"] = audioError }
            return d
        }
    }

    /// Same list as OLTgcallsVersion.server (pinned by olcall/integration/clientcontract_test.go).
    public static let serverVersions = OLTgcallsVersion.server

    public let peer: Peer
    public private(set) var state: UiState
    /// Main thread.
    public var onUiState: ((UiState) -> Void)?
    public var onRemoteVideoView: ((UIView) -> Void)?
    public var onLocalVideoView: ((UIView) -> Void)?

    private let call: OLCall
    private var connectedAt: Date?
    private var timer: Timer?

    public init(serverURL: URL, joinToken: String, peer: Peer, video: Bool, usesCallKit: Bool = false,
                appIceServers: Any? = nil) throws {
        self.peer = peer
        call = try OLCall(serverURL: serverURL, joinToken: joinToken, video: video, usesCallKit: usesCallKit,
                          appIceServers: appIceServers)
        state = UiState(isVideoCall: video, cameraOn: video, speakerOn: video)
        super.init()
    }

    public func start() {
        call.onEvent = { [weak self] in self?.handle($0) }
        call.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        publish()
    }

    public func setMuted(_ muted: Bool) { call.setMuted(muted); update { $0.muted = muted } }

    public func setCameraEnabled(_ on: Bool) {
        call.setVideoEnabled(on)
        update { $0.cameraOn = on; $0.isVideoCall = $0.isVideoCall || on }
    }

    public func switchCamera() {
        let front = !state.frontCamera
        call.switchCamera(front: front)
        update { $0.frontCamera = front }
    }

    public func setSpeaker(_ on: Bool) { call.setSpeaker(on); update { $0.speakerOn = on } }
    public func hangup() { call.hangup() }

    public func callKitDidActivate(_ s: AVAudioSession) { call.callKitDidActivate(s) }
    public func callKitDidDeactivate(_ s: AVAudioSession) { call.callKitDidDeactivate(s) }

    // main thread
    private func handle(_ e: OLCall.Event) {
        switch e {
        case let .state(st, remoteVideo, remoteMuted):
            update { s in
                switch st {
                case .connected:
                    if self.connectedAt == nil { self.connectedAt = Date() }
                    s.phase = .inCall
                case .reconnecting:
                    if self.connectedAt != nil { s.phase = .reconnecting }
                default:
                    break
                }
                s.remoteVideoOn = remoteVideo
                s.remoteMuted = remoteMuted
            }
        case let .audioFailed(why):
            update { $0.audioError = why }
        case let .remoteVideoView(v):
            onRemoteVideoView?(v)
        case let .localVideoView(v):
            onLocalVideoView?(v)
        case let .ended(reason):
            timer?.invalidate()
            timer = nil
            update { $0.phase = .ended; $0.endReason = reason }
        case .joined, .audio, .route:
            break
        }
    }

    private func update(_ f: (inout UiState) -> Void) {
        f(&state)
        publish()
    }

    private func publish() {
        let s = state
        onUiState?(s)
    }

    private func tick() {
        guard let t = connectedAt, state.phase != .ended else { return }
        let sec = Int(Date().timeIntervalSince(t))
        if sec != state.elapsedSec { update { $0.elapsedSec = sec } }
    }
}
