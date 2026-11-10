// OLTgcallsCall — one raw tgcalls Instance on iOS (no NTgCalls).
//
// Constructs tgcalls::Instance (InstanceV2Impl, versions 7.0.0–13.0.0) through
// TgVoipWebrtc's OngoingCallThreadLocalContextWebrtc — the ObjC++ layer
// Telegram-iOS itself uses (Sources/OngoingCallThreadLocalContext.mm). That file
// IS the ObjC++ shim: it builds tgcalls::Descriptor, owns the Instance, maps
// callbacks onto our queue, and passes signaling blobs through byte-for-byte
// (signalingDataEmitted -> NSData copy; addSignalingData [Swift: addSignaling(_:)] -> receiveSignalingData).
// No second shim is needed because Swift only ever calls its ObjC API.
//
// Proven configuration (Linux, same library, through the olcall Pion server:
// 14/14 matrix + 5/5 cross-version cells): P2P on, no Telegram reflectors, VP8
// preferred (the relay forwards VP8), Opus (tgcalls' only audio codec in V2).
// Gap item 3 (2026-11-09): the joined frame's coturn STUN/TURN list is passed as
// rtcServers (same as Android's JNI), so direct host/srflx pairs win and the TURN
// relay is the fallback for carrier-grade NAT.
//
// Threading: create and use on `queue` (the wrapper asserts it). Callbacks are
// delivered on `queue`.
import Foundation
import UIKit
#if canImport(TgVoipWebrtc)
import TgVoipWebrtc
#endif

public final class OLTgcallsCall {
    public enum State: String { case initializing, connected, failed, reconnecting }

    public struct Config {
        public var version: String
        /// 256-byte call key from the olcall "joined" frame.
        public var key: Data
        public var isOutgoing: Bool
        /// Start with the front camera on.
        public var video: Bool
        /// tgcalls/WebRTC log + stats files (app caches dir; uploaded nowhere).
        public var logDirectory: URL
        public var traceId: String
        /// coturn STUN + TURN (joined iceServers, else CallMedia.iceServers): tgcalls Descriptor.rtcServers.
        /// Direct first (allowP2P stays on), relay fallback. Empty = direct only.
        public var rtcServers: [OLRtcServers.Server]
        public init(version: String, key: Data, isOutgoing: Bool, video: Bool, logDirectory: URL, traceId: String,
                    rtcServers: [OLRtcServers.Server] = []) {
            self.version = version; self.key = key; self.isOutgoing = isOutgoing
            self.video = video; self.logDirectory = logDirectory; self.traceId = traceId
            self.rtcServers = rtcServers
        }
    }

    /// tgcalls versions this binary can create (InstanceV2Impl registration).
    public static func linkedVersions() -> [String] {
        OngoingCallThreadLocalContextWebrtc.versions(withIncludeReference: false)
    }

    /// queue: tgcalls state, far side's video on/off, far side muted.
    public var onState: ((State, _ remoteVideoActive: Bool, _ remoteMuted: Bool) -> Void)?

    private let queue: OLCallQueue
    private let context: OngoingCallThreadLocalContextWebrtc
    private var capturer: OngoingCallThreadLocalContextVideoCapturer?

    /// - Parameters:
    ///   - audioDevice: created before the call; owns AVAudioSession (OLCallAudioDevice).
    ///   - sendSignalingData: every blob tgcalls emits, unchanged, for the WebSocket relay.
    public init(config: Config, queue: OLCallQueue, audioDevice: OLCallAudioDevice,
                sendSignalingData: @escaping (Data) -> Void) throws {
        precondition(queue.isCurrent(), "OLTgcallsCall must be created on its OLCallQueue")
        guard config.key.count == 256 else { throw OLTgcallsError.badKey }
        guard Self.linkedVersions().contains(config.version) else { throw OLTgcallsError.unsupportedVersion(config.version) }
        self.queue = queue
        if config.video {
            // "" = front camera (VideoCapturerInterfaceImpl: anything not prefixed "back").
            capturer = OngoingCallThreadLocalContextVideoCapturer(deviceId: "", keepLandscape: false)
        }
        let dir = config.logDirectory
        context = OngoingCallThreadLocalContextWebrtc(
            version: config.version,
            customParameters: "{}",
            queue: queue,
            proxy: nil,
            networkType: .wifi,               // initial hint only; tgcalls observes the real network
            dataSaving: .never,
            derivedState: Data(),
            key: config.key,
            isOutgoing: config.isOutgoing,
            connections: OLRtcServers.connections(config.rtcServers), // coturn STUN/TURN (reflectorId 0); no Telegram reflectors
            maxLayer: OngoingCallThreadLocalContextWebrtc.maxLayer(),
            allowP2P: true,                   // proven path: host/srflx candidates to the Pion leg
            allowTCP: false,
            enableStunMarking: false,
            logPath: dir.appendingPathComponent("olcall-\(config.traceId).tgcalls.log").path,
            statsLogPath: dir.appendingPathComponent("olcall-\(config.traceId).stats.json").path,
            sendSignalingData: sendSignalingData,
            videoCapturer: capturer,
            preferredVideoCodec: "VP8",       // olcall relays VP8 only (media.VideoCodec)
            audioInputDeviceId: "",
            audioDevice: audioDevice.shared,  // Telegram's shared ADM; starts only once the session is active
            directConnection: nil)
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

    /// A blob from the server ("blob" frame), unchanged.
    public func receiveSignalingData(_ data: Data) {
        queue.dispatch { self.context.addSignaling(data) }
    }

    public func setMuted(_ muted: Bool) { queue.dispatch { self.context.setIsMuted(muted) } }

    /// Camera on/off. The first "on" in an audio call adds a video channel (tgcalls renegotiates).
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

    /// Far side's video (tgcalls VideoMetalView / sample-buffer view). Main queue.
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

    public var description: String {
        switch self {
        case .badKey: return "call key must be 256 bytes"
        case let .unsupportedVersion(v): return "this TgVoipWebrtc build cannot create tgcalls \(v)"
        case let .noCommonVersion(local): return "no tgcalls version in common with the server (linked: \(local))"
        }
    }
}
