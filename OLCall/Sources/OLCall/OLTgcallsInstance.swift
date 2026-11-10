// OLTgcallsInstance — one tgcalls engine instance (InstanceV2Impl) through TgVoipWebrtc's
// OngoingCallThreadLocalContextWebrtc. Signaling blobs pass through unchanged both ways.
//
// Configuration for the Open Lounge Pion server:
//   - relay only: the engine's direct-path switch is off, so every media path goes through the coturn TURN servers
//     from the joined frame (TURN is mandatory; a list without TURN never creates an instance)
//   - no Telegram reflectors (every relay server has reflectorId 0)
//   - VP8 preferred (the Pion server forwards VP8), Opus audio
//   - the audio device comes from OLCallAudioDevice, the session owner
//
// Threading: create and use on `queue` (asserted). Callbacks are delivered on `queue`.
import Foundation
import OLCallCore
import TgVoipWebrtc
import UIKit

public final class OLTgcallsInstance {
    public enum State: String { case initializing, connected, failed, reconnecting }

    public struct Config {
        public var version: String
        /// 256-byte call key from the olcall "joined" frame.
        public var key: Data
        public var isOutgoing: Bool
        /// Start with the front camera on (video call).
        public var video: Bool
        /// Engine log + stats files (app caches dir; uploaded nowhere).
        public var logDirectory: URL
        public var traceId: String
        /// coturn STUN + TURN from the joined frame; must contain TURN.
        public var rtcServers: [OLRtcServers.Server]

        public init(version: String, key: Data, isOutgoing: Bool, video: Bool, logDirectory: URL, traceId: String,
                    rtcServers: [OLRtcServers.Server]) {
            self.version = version; self.key = key; self.isOutgoing = isOutgoing
            self.video = video; self.logDirectory = logDirectory; self.traceId = traceId
            self.rtcServers = rtcServers
        }
    }

    /// Engine versions this binary can create.
    public static func linkedVersions() -> [String] {
        OngoingCallThreadLocalContextWebrtc.versions(withIncludeReference: false)
    }

    /// queue: engine state, far side's video on/off, far side muted.
    public var onState: ((State, _ remoteVideoActive: Bool, _ remoteMuted: Bool) -> Void)?
    /// Far side's audio level (receive side), on the engine's thread.
    public var onRemoteAudioLevel: ((Float) -> Void)?

    private let queue: OLCallQueue
    private let context: OngoingCallThreadLocalContextWebrtc
    private var capturer: OngoingCallThreadLocalContextVideoCapturer?

    /// - Parameters:
    ///   - audioDevice: created before the instance; owns AVAudioSession.
    ///   - sendSignalingData: every blob the engine emits, unchanged, for the WebSocket.
    public init(config: Config, queue: OLCallQueue, audioDevice: OLCallAudioDevice,
                sendSignalingData: @escaping (Data) -> Void) throws {
        precondition(queue.isCurrent(), "OLTgcallsInstance must be created on its OLCallQueue")
        guard config.key.count == 256 else { throw OLTgcallsError.badKey }
        guard Self.linkedVersions().contains(config.version) else { throw OLTgcallsError.unsupportedVersion(config.version) }
        guard OLRtcServers.hasTurn(config.rtcServers) else { throw OLTgcallsError.noTurn }
        self.queue = queue
        if config.video {
            // "" = front camera.
            capturer = OngoingCallThreadLocalContextVideoCapturer(deviceId: "", keepLandscape: false)
        }
        let dir = config.logDirectory
        context = OngoingCallThreadLocalContextWebrtc(
            version: config.version,
            customParameters: "{}",
            queue: queue,
            proxy: nil,
            networkType: .wifi,               // initial hint only; the engine observes the real network
            dataSaving: .never,
            derivedState: Data(),
            key: config.key,
            isOutgoing: config.isOutgoing,
            connections: Self.connections(config.rtcServers),
            maxLayer: OngoingCallThreadLocalContextWebrtc.maxLayer(),
            allowP2P: false,                  // relay only: TURN carries every call
            allowTCP: false,
            enableStunMarking: false,
            logPath: dir.appendingPathComponent("olcall-\(config.traceId).engine.log").path,
            statsLogPath: dir.appendingPathComponent("olcall-\(config.traceId).stats.json").path,
            sendSignalingData: sendSignalingData,
            videoCapturer: capturer,
            preferredVideoCodec: "VP8",
            audioInputDeviceId: "",
            audioDevice: audioDevice.shared,
            directConnection: nil)
        context.audioLevelUpdated = { [weak self] level in self?.onRemoteAudioLevel?(level) }
        context.stateChanged = { [weak self] state, _, remoteVideo, remoteAudio, _, _ in
            let s: State
            switch state {
            case .connected: s = .connected
            case .failed: s = .failed
            case .reconnecting: s = .reconnecting
            default: s = .initializing
            }
            self?.onState?(s, remoteVideo == .active, remoteAudio == .muted)
        }
    }

    /// Relay servers as engine descriptors (reflectorId 0 = a plain STUN/TURN server).
    public static func connections(_ list: [OLRtcServers.Server]) -> [OngoingCallConnectionDescriptionWebrtc] {
        list.map { s in
            OngoingCallConnectionDescriptionWebrtc(reflectorId: 0, hasStun: !s.isTurn, hasTurn: s.isTurn, hasTcp: s.isTurn && s.isTcp,
                                                   ip: s.host, port: Int32(s.port), username: s.login, password: s.password)
        }
    }

    /// A blob from the server ("blob" frame), unchanged.
    public func receiveSignalingData(_ data: Data) {
        queue.dispatch { self.context.addSignaling(data) }
    }

    public func setMuted(_ muted: Bool) { queue.dispatch { self.context.setIsMuted(muted) } }

    /// Camera on/off. The first "on" in an audio call adds a video channel (the engine renegotiates).
    public func setVideoEnabled(_ on: Bool) {
        queue.dispatch {
            if on, self.capturer == nil {
                let cap = OngoingCallThreadLocalContextVideoCapturer(deviceId: "", keepLandscape: false)
                self.capturer = cap
                self.context.requestVideo(cap)
            } else {
                self.capturer?.setIsVideoEnabled(on)
            }
        }
    }

    public func switchCamera(front: Bool) {
        queue.dispatch { self.capturer?.switchVideoInput(front ? "" : "back") }
    }

    /// Far side's video view. Main queue.
    public func makeIncomingVideoView(_ completion: @escaping (UIView?) -> Void) {
        queue.dispatch {
            self.context.makeIncomingVideoView { view in DispatchQueue.main.async { completion(view) } }
        }
    }

    /// Local camera preview. Main queue; nil while the camera is off.
    public func makeOutgoingVideoView(_ completion: @escaping (UIView?) -> Void) {
        queue.dispatch {
            guard let cap = self.capturer else { DispatchQueue.main.async { completion(nil) }; return }
            cap.makeOutgoingVideoView(false) { view, _ in DispatchQueue.main.async { completion(view) } }
        }
    }

    public func stop(_ completion: (() -> Void)? = nil) {
        queue.dispatch {
            self.capturer?.setIsVideoEnabled(false)
            self.context.stop { _, _, _, _, _ in completion?() }
        }
    }
}

public enum OLTgcallsError: Error, CustomStringConvertible {
    case badKey
    case unsupportedVersion(String)
    case noCommonVersion([String])
    case noTurn

    public var description: String {
        switch self {
        case .badKey: return "call key must be 256 bytes"
        case let .unsupportedVersion(v): return "this engine build cannot create version \(v)"
        case let .noCommonVersion(local): return "no engine version in common with the server (linked: \(local))"
        case .noTurn: return "joined frame carried no TURN server"
        }
    }
}
