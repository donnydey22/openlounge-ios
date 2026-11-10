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
    private var pending: Reply?
    private var connected = false
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
        case .restartIce, .signalConnected, .videoLayout:
            reply(true, true, nil) // tgcalls follows network changes itself; the app lays out its own video
        case let .unknown(op):
            reply(false, nil, "unknown op: \(op)")
        }
    }

    private func connect(id: String, media raw: OLJSON, video wantVideo: Bool, reply: @escaping Reply) {
        if callId == id, engine != nil {
            if connected { reply(true, result(), nil) } else { pending = reply }
            return
        }
        close()
        callId = id
        video = wantVideo
        gate.authorize(wantVideo ? .videoCall : .audioCall) { ok in
            DispatchQueue.main.async {
                guard self.callId == id else { return reply(false, nil, "cancelled") }
                guard ok else { self.callId = nil; return reply(false, nil, "permission-denied") }
                guard let media = OLCallMedia.parse(raw.foundation) else { self.callId = nil; return reply(false, nil, "unsupported-media") }
                let usesCallKit = CallCenter.shared.hasCall(id)
                let e: OLTgcallsEngine
                do { e = try OLTgcallsEngine(media: media, video: wantVideo, usesCallKit: usesCallKit) } catch {
                    self.callId = nil
                    return reply(false, nil, "native-create-failed")
                }
                self.engine = e
                self.pending = reply
                self.connected = false
                self.remoteVideo = false
                e.onEvent = { [weak self, weak e] ev in
                    guard let self, let e, self.engine === e else { return }
                    self.onEvent(ev, id: id)
                }
                CallController.shared.engineStarted(callId: id, video: wantVideo)
                e.start()
                if self.muted { e.setMuted(true) }
                if usesCallKit, CallCenter.shared.audioActive { e.callKitDidActivate(AVAudioSession.sharedInstance()) }
            }
        }
    }

    private func result() -> [String: Any] { ["engine": "tgcalls", "path": "olcall", "video": video] }

    private func onEvent(_ ev: OLTgcallsEngine.Event, id: String) {
        switch ev {
        case let .state(st, rv, _):
            if st == .connected && !connected {
                connected = true
                host?.emitNativeMedia(["state": "connected", "callId": id])
                pending?(true, result(), nil)
                pending = nil
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
        case let .ended(reason):
            let normal = reason == "local-hangup" || reason.hasPrefix("bye:")
            if let p = pending { p(false, nil, "network:olcall:\(reason)"); pending = nil }
            else if !normal { host?.emitNativeMedia(["state": "failed", "callId": id]) }
            engine = nil
            callId = nil
            connected = false
            muted = false
            CallController.shared.engineEnded(callId: id)
        case .joined, .audio, .audioFailed, .route:
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
        pending?(false, nil, "cancelled")
        pending = nil
        engine?.hangup() // ends with "local-hangup" -> onEvent(.ended) clears the rest
        if engine == nil { callId = nil; connected = false; muted = false }
    }

    func callKitDidActivate(_ s: AVAudioSession) { engine?.callKitDidActivate(s) }
    func callKitDidDeactivate(_ s: AVAudioSession) { engine?.callKitDidDeactivate(s) }
}
