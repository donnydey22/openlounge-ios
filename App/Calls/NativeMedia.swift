// NativeMedia — the page's nativeMedia(cmd) commands, answered with one OLTgcallsEngine per call
// (the same ops and replies as the Open Lounge Android app's call media).
//
//   page (openlounge.app)                          this app
//   starts / accepts the call on its own         -> connect {callId, media, video, caller}
//   realtime socket; CallMedia from the reply       permission gate (mic, or camera + mic)
//                                                   OLTgcallsEngine -> wss /v1/call (Pion) -> TURN
//   <- "openlounge:native-media" {state}            connected / remote-video / failed
//
// connect resolves once the call is connected ({engine:"tgcalls", path:"olcall", video}) and is
// rejected with "permission-denied" (silently, no prompt again) or "network:olcall:<reason>".
import AVFAudio
import Foundation
import OLCall
import OLCallCore
import OLShellCore
import UIKit

final class NativeMedia {
    static let shared = NativeMedia()
    typealias Reply = (_ ok: Bool, _ result: Any?, _ error: String?) -> Void

    weak var host: ShellHost?
    private let gate = OLCallPermissionGate(provider: SystemPermissions())
    private var engine: OLTgcallsEngine?
    private(set) var callId: String?
    private static let connectTimeout: TimeInterval = 45
    private var pending: [Reply] = []
    private var connectWatchdog: DispatchWorkItem?
    private var generation = 0
    private var connected = false
    private var ownReconnecting = false
    private var peerReconnecting = false
    private var video = false
    private var remoteVideo = false
    private var muted = false

    var isActive: Bool { engine != nil }

    func handle(_ cmd: [String: OLJSON], reply: @escaping Reply) {
        guard let c = OLMediaCommand.parse(cmd) else { return reply(false, nil, "bad command") }
        switch c {
        case let .connect(id, media, wantVideo, _):
            connect(id: id, media: media, video: wantVideo, reply: reply)
        case let .camera(on, front):
            camera(on: on, front: front, reply: reply)
        case let .mute(m):
            setMuted(m)
            reply(true, true, nil)
        case .close:
            close()
            reply(true, true, nil)
        case .prewarm:
            reply(true, ["engine": "tgcalls", "available": true], nil)
        case .stats:
            reply(true, [Any](), nil)
        case .restartIce:
            guard let engine, engine.restartIce() else { return reply(false, nil, "olcall not connected") }
            reply(true, ["accepted": true], nil)
        case .signalConnected, .videoLayout:
            reply(true, true, nil) // the app lays out its own video; signaling state is server-owned
        case let .unknown(op):
            reply(false, nil, "unknown op: \(op)")
        }
    }

    private func connect(id: String, media raw: OLJSON, video wantVideo: Bool, reply: @escaping Reply) {
        if callId == id, engine != nil {
            if connected { reply(true, result(), nil) } else { pending.append(reply) }
            return
        }
        close()
        generation += 1
        let attempt = generation
        callId = id
        video = wantVideo
        pending = [reply]
        authorizeCamOrAudio(id: id, video: wantVideo, generation: attempt) { ok, wantVideo in
            DispatchQueue.main.async {
                guard self.callId == id, self.generation == attempt else { return }
                guard ok else { self.failConnect(id: id, attempt: attempt, reason: "permission-denied", emit: false); return }
                guard let media = OLCallMedia.parse(raw.foundation) else {
                    self.failConnect(id: id, attempt: attempt, reason: "unsupported-media", emit: false); return
                }
                let usesCallKit = CallCenter.shared.hasCall(id)
                let e: OLTgcallsEngine
                do { e = try OLTgcallsEngine(media: media, video: wantVideo, usesCallKit: usesCallKit) } catch {
                    self.failConnect(id: id, attempt: attempt, reason: "native-create-failed", emit: false); return
                }
                self.engine = e
                self.connected = false
                self.remoteVideo = false
                e.onEvent = { [weak self, weak e] ev in
                    guard let self, let e, self.engine === e, self.generation == attempt else { return }
                    self.onEvent(ev, id: id)
                }
                CallController.shared.engineStarted(callId: id, video: wantVideo)
                e.audioTrigger = UIApplication.shared.applicationState == .active ? "foreground" : "push"
                e.start()
                let timeout = DispatchWorkItem { [weak self] in
                    self?.failConnect(id: id, attempt: attempt, reason: "network:olcall:connect-timeout", emit: true)
                }
                self.connectWatchdog = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeout)
                let now = Date()
                for ev in self.earlyCallKit.suffix(8) {
                    e.logAppEvent(ev.name, ["beforeEngine": true, "msBeforeEngine": Int(now.timeIntervalSince(ev.at) * 1000),
                                            "categoryAtEvent": ev.category, "modeAtEvent": ev.mode])
                }
                self.earlyCallKit.removeAll()
                if self.muted { e.setMuted(true) }
                let replay = usesCallKit && CallCenter.shared.audioActive
                e.logAppEvent("callkit_state_at_connect", ["callkit": usesCallKit, "audioActive": CallCenter.shared.audioActive, "replayActivate": replay])
                if replay { e.callKitDidActivate(AVAudioSession.sharedInstance()) }
            }
        }
    }

    private func completePending(_ ok: Bool, _ result: Any? = nil, _ error: String? = nil) {
        let replies = pending
        pending = []
        replies.forEach { $0(ok, result, error) }
    }

    private func failConnect(id: String, attempt: Int, reason: String, emit: Bool) {
        guard generation == attempt, callId == id else { return }
        connectWatchdog?.cancel(); connectWatchdog = nil
        completePending(false, nil, reason)
        if emit {
            host?.emitNativeMedia(["state": "failed", "callId": id, "reason": reason])
            CallController.shared.showNetworkFailure(reason == "network:olcall:connect-timeout"
                ? "Could not connect on this network. Try again." : "Call audio could not start. Try again.")
            host?.dispatchNativeCall(["type": "call:hangup", "callId": id, "reason": reason])
        }
        engine?.hangup()
        engine = nil
        callId = nil
        connected = false
        CallController.shared.engineEnded(callId: id)
    }

    /// t6111u: every door opens with the camera on. Camera refused (mic granted) = join with audio and the camera-off
    /// tile (the page hears "camera-unavailable"), never a failed call. Mic refused still fails silently, as before.
    private func authorizeCamOrAudio(id: String, video: Bool, generation: Int, _ done: @escaping (Bool, Bool) -> Void) {
        gate.authorize(video ? .videoCall : .audioCall) { ok in
            guard !ok, video else { return done(ok, video) }
            self.gate.authorize(.audioCall) { mic in
                if mic {
                    DispatchQueue.main.async {
                        guard self.callId == id, self.generation == generation else { return }
                        self.video = false
                        self.host?.emitNativeMedia(["state": "camera-unavailable", "callId": id])
                    }
                }
                done(mic, false)
            }
        }
    }

    private func result() -> [String: Any] { ["engine": "tgcalls", "path": "olcall", "video": video] }

    private func onEvent(_ ev: OLTgcallsEngine.Event, id: String) {
        switch ev {
        case let .state(st, rv, rm):
            if CallController.shared.remoteMuted != rm { CallController.shared.remoteMuted = rm }
            // Mid-call "Reconnecting…": this phone's engine lost its path after having connected.
            if connected { ownReconnecting = st == .reconnecting; CallController.shared.setReconnecting(callId: id, on: ownReconnecting || peerReconnecting) }
            if st == .connected && !connected {
                connected = true
                connectWatchdog?.cancel(); connectWatchdog = nil
                host?.emitNativeMedia(["state": "connected", "callId": id])
                completePending(true, result(), nil)
                CallController.shared.mediaConnected(callId: id)
            }
            if rv != remoteVideo {
                remoteVideo = rv
                host?.emitNativeMedia(["state": "remote-video", "callId": id, "on": rv])
                CallController.shared.remoteVideoOn = rv
            }
        case let .remoteVideoView(v):
            CallController.shared.remoteVideoView = v
        case let .localVideoView(v):
            CallController.shared.localVideoView = v
        case let .lifecycle(l):
            CallController.shared.observeLifecycle(callId: id, l) // server-owned; observe only
        case let .ended(reason):
            let normal = reason == "local-hangup" || reason.hasPrefix("bye:")
            connectWatchdog?.cancel(); connectWatchdog = nil
            let reasonText = "network:olcall:\(reason)"
            completePending(false, nil, reasonText)
            if !normal {
                host?.emitNativeMedia(["state": "failed", "callId": id, "reason": reasonText])
                CallController.shared.showNetworkFailure("The media connection ended. Try again.")
            }
            engine = nil
            callId = nil
            connected = false
            ownReconnecting = false
            peerReconnecting = false
            CallController.shared.setReconnecting(callId: id, on: false)
            muted = false
            CallController.shared.engineEnded(callId: id)
        case let .peerReconnecting(on):
            peerReconnecting = on
            CallController.shared.setReconnecting(callId: id, on: ownReconnecting || peerReconnecting)
        case let .audioFailed(reason):
            failConnect(id: id, attempt: generation, reason: "audio:\(reason)", emit: true)
        case .mediaFlowing, .joined, .audio, .route:
            break
        }
    }

    private func camera(on: Bool, front: Bool, reply: @escaping Reply) {
        guard let e = engine else { return reply(false, nil, "no call") }
        guard on else {
            e.setVideoEnabled(false)
            CallController.shared.cameraOn = false
            return reply(true, true, nil)
        }
        gate.authorize(.videoToggle) { ok in
            DispatchQueue.main.async {
                // camera denied mid-call: the call stays on audio, nothing is shown
                guard ok, self.engine === e else { return reply(false, nil, "permission-denied") }
                e.setVideoEnabled(true)
                e.switchCamera(front: front)
                self.video = true
                CallController.shared.cameraOn = true
                reply(true, true, nil)
            }
        }
    }

    func setMuted(_ m: Bool) {
        muted = m
        engine?.setMuted(m)
        CallController.shared.muted = m
    }

    func setSpeaker(_ on: Bool) { engine?.setSpeaker(on) }

    func close() {
        generation += 1
        connectWatchdog?.cancel(); connectWatchdog = nil
        completePending(false, nil, "cancelled")
        let id = callId
        let old = engine
        engine = nil
        callId = nil
        connected = false
        ownReconnecting = false
        peerReconnecting = false
        remoteVideo = false
        muted = false
        old?.onEvent = nil
        old?.hangup()
        if let id { CallController.shared.engineEnded(callId: id) }
    }

    /// CallKit audio callbacks that arrived while no engine existed (push-wake: CallKit can activate before the
    /// page connects). Logging only — the engine still gets activation from the audioActive replay in connect.
    private var earlyCallKit: [(name: String, at: Date, category: String, mode: String)] = []

    func callKitDidActivate(_ s: AVAudioSession) {
        if let e = engine { e.callKitDidActivate(s) } else { earlyCallKit.append(("callkit_did_activate", Date(), s.category.rawValue, s.mode.rawValue)) }
    }
    /// CallKit deactivated the session (iOS ring calls only; link joins never use CallKit). The engine decides Ended vs
    /// Reconnecting and tells the call server itself (see OLTgcallsEngine.callKitDidDeactivate).
    func callKitDidDeactivate(_ s: AVAudioSession) {
        guard let e = engine else {
            earlyCallKit.append(("callkit_did_deactivate", Date(), s.category.rawValue, s.mode.rawValue))
            return
        }
        e.callKitDidDeactivate(s, callKitHoldsCall: callId.map { CallCenter.shared.hasCall($0) } ?? false)
    }

    /// Before fulfilling CXStartCallAction / CXAnswerCallAction (see OLCallAudioDevice.configureSessionForCallKit).
    static func configureSessionForCallKit() { OLCallAudioDevice.configureSessionForCallKit() }
}
