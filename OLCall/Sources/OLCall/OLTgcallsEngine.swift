// OLTgcallsEngine — the iPhone client of the olcall Pion server, structured like Android's
// OlTgcallsEngine.kt:
//
//   wss://turn.openlounge.app/v1/call  <->  this class  <->  OLTgcallsInstance (tgcalls)
//
// One call, one path: open the WebSocket, send join {token}, receive joined {key, isOutgoing,
// iceServers}, create the engine instance with the joined TURN list, relay blobs unchanged both
// ways, hang up / end. Every state change goes through OLCallStates (one log line each).
//
// Threading: socket callbacks and engine callbacks only enqueue onto `queue`. Listener events are
// delivered on the main queue.
import AVFAudio
import Foundation
import OLCallCore
import UIKit

public final class OLTgcallsEngine {
    public enum Event {
        case joined(isOutgoing: Bool, version: String)
        case state(OLTgcallsInstance.State, remoteVideoActive: Bool, remoteMuted: Bool)
        case audio(active: Bool)
        case audioFailed(String)
        case remoteVideoView(UIView)
        case localVideoView(UIView)
        /// t5456: first inbound media after tgcalls connected (audible remote level, or a rendered remote
        /// frame). Once per call. The call timer starts on this, not on the answer or the Pion join.
        case mediaFlowing(source: String)
        case route(String)
        case ended(String)
    }

    /// Main queue.
    public var onEvent: ((Event) -> Void)?

    public let traceId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    public let version: String
    /// idle/joining/offering/answering/connected/failed; used on `queue`.
    public let states: OLCallStates
    /// No Established this long after "joined" -> failed with the diagnosed reason (e.g. ice-stalled).
    public static let connectTimeout: TimeInterval = 30

    private let queue = OLCallQueue(label: "ol.call.engine")
    private let media: OLCallMedia
    private let video: Bool
    private let crumbs: OLBreadcrumbs
    private let audio: OLCallAudioDevice
    private var socket: URLSessionWebSocketTask?
    private var instance: OLTgcallsInstance?
    private var seq: UInt64 = 0
    private var ended = false
    private var pingTimer: DispatchSourceTimer?
    private var connectWatchdog: DispatchWorkItem?
    private var peerSeen = false
    private var connected = false
    private var remoteMuted = false
    private let inboundSilence = OLSilenceWatchdog(window: 8, maxRecoveries: 0)
    private var remoteVideoActive = false
    /// Main thread: stable containers the UI shows (OLVideoView); the engine views go inside.
    private var remoteView: OLVideoView?
    private var localView: OLVideoView?
    private var videoTimer: Timer?
    private var watchdog = OLVideoWatchdog()
    private var statsWindow = (remote: 0, local: 0, ticks: 0)
    /// Engine queue: `.mediaFlowing` was emitted.
    private var flowing = false
    /// Durable call log for this leg (OLCallLog: on-disk queue, uploaded to /api/call-log).
    public let callLog: OLCallLog

    /// - Parameters:
    ///   - media: the CallMedia the backend issued for THIS participant (url + join token).
    ///   - video: start with the camera on (and the loudspeaker).
    ///   - usesCallKit: forward CXProvider didActivate/didDeactivate to callKitDidActivate/Deactivate.
    public init(media: OLCallMedia, video: Bool, usesCallKit: Bool) throws {
        let local = OLTgcallsInstance.linkedVersions()
        guard let v = OLVersions.pick(local: local) else { throw OLTgcallsError.noCommonVersion(local) }
        version = v
        self.media = media
        self.video = video
        let c = OLBreadcrumbs(crumbURL: OLBreadcrumbs.crumbURL(forCallURL: media.url), engine: OLCallFrames.engine)
        crumbs = c
        audio = OLCallAudioDevice(usesCallKit: usesCallKit, crumbs: c)
        states = OLCallStates(sink: { line in
            NSLog("%@", line)
            c.event("state", line, level: line.contains(" -> failed ") ? "error" : "info")
        })
        callLog = OLCallLog.forLeg(token: media.token, appCallId: media.callId, video: video, device: OLDevice.model,
                                   os: "iOS \(UIDevice.current.systemVersion)", engine: OLCallFrames.engine)
        callLog.attach(states)
    }

    public func start() {
        crumbs.traceId = traceId
        audio.onActiveChanged = { [weak self] on in self?.emit(.audio(active: on)) }
        audio.onRouteChanged = { [weak self] r in self?.emit(.route(r)) }
        audio.begin(speakerOn: video) { [weak self] outcome in
            if case let .failed(domain, code, first) = outcome {
                self?.callLog.event("audio_session", reason: "audio_session_handoff_failure", detail: "\(domain):\(code):\(first)")
                self?.emit(.audioFailed("\(domain):\(code):\(first)"))
            }
        }
        let join = OLCallFrames.Join(token: media.token, traceId: traceId, version: version, device: OLDevice.model,
                                     os: "iOS \(UIDevice.current.systemVersion)")
        queue.dispatch {
            let t = URLSession.shared.webSocketTask(with: self.media.url)
            t.maximumMessageSize = 1 << 20
            self.socket = t
            t.resume()
            self.crumbs.event("ws", "open")
            self.send(OLCallFrames.join(join, seq: self.nextSeq()))
            self.states.setState(.joining, reason: "join-sent")
            self.receive()
            let timer = DispatchSource.makeTimerSource(queue: nil)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                self?.queue.dispatch { guard let self else { return }; self.send(OLCallFrames.ping(seq: self.nextSeq())) }
            }
            timer.resume()
            self.pingTimer = timer
        }
    }

    public func setMuted(_ m: Bool) { queue.dispatch { self.instance?.setMuted(m) } }

    /// Camera on/off. Call only after the camera permission gate passed.
    public func setVideoEnabled(_ on: Bool) {
        queue.dispatch {
            guard let i = self.instance else { return }
            i.setVideoEnabled(on)
            if on { i.makeOutgoingVideoView { [weak self] v in if let v { self?.showLocal(v) } } }
        }
    }

    public func switchCamera(front: Bool) { queue.dispatch { self.instance?.switchCamera(front: front) } }
    public func setSpeaker(_ on: Bool) { audio.setSpeaker(on) }

    public func hangup() {
        queue.dispatch {
            guard !self.ended else { return }
            self.send(OLCallFrames.hangup(seq: self.nextSeq()))
            self.end("local-hangup")
        }
    }

    public func callKitDidActivate(_ s: AVAudioSession) { audio.callKitDidActivate(s) }
    public func callKitDidDeactivate(_ s: AVAudioSession) { audio.callKitDidDeactivate(s) }

    // MARK: socket (queue)

    private func nextSeq() -> UInt64 { seq += 1; return seq }

    private func send(_ frame: [String: Any]) {
        guard !ended, let socket, let text = OLCallFrames.encode(frame) else { return }
        socket.send(.string(text)) { [weak self] err in
            if err != nil { self?.crumbs.event("ws", "send-failed", level: "error") }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.dispatch {
                guard !self.ended else { return }
                switch result {
                case let .failure(err):
                    let code = self.socket?.closeCode ?? .invalid
                    if code != .invalid {
                        self.end("ws-closed:\(code.rawValue)")
                    } else {
                        self.crumbs.event("ws", "failure:\((err as NSError).code)", level: "error")
                        self.end("ws-failure")
                    }
                case let .success(msg):
                    if case let .string(text) = msg { self.onFrame(OLCallFrames.decode(text)) }
                    if !self.ended { self.receive() }
                }
            }
        }
    }

    private func onFrame(_ f: OLCallFrames.Inbound) {
        switch f {
        case let .joined(j):
            crumbs.callId = j.callId
            crumbs.leg = j.leg
            states.callId = j.callId
            states.setState(j.isOutgoing ? .offering : .answering, reason: "joined")
            crumbs.event("tg", "joined:outgoing=\(j.isOutgoing):version=\(version)")
            if !j.serverVersions.isEmpty && !j.serverVersions.contains(version) {
                crumbs.event("tg", "server-lacks-version:\(version)", level: "error")
                end("version-mismatch")
                return
            }
            let rtc = OLRtcServers.fromIceServers(j.iceServers)
            crumbs.event("tg", "rtc-servers:" + OLRtcServers.summary(rtc))
            callLog.turnServers = rtc.filter { $0.isTurn }.count
            callLog.event("rtc_servers", extra: ["turnServers": rtc.filter { $0.isTurn }.count, "stunServers": rtc.filter { !$0.isTurn }.count])
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            do {
                var key = j.key
                let i = try OLTgcallsInstance(
                    config: .init(version: version, key: key, isOutgoing: j.isOutgoing, video: video,
                                  logDirectory: caches, traceId: traceId, rtcServers: rtc),
                    queue: queue, audioDevice: audio,
                    sendSignalingData: { [weak self] blob in
                        guard let self else { return }
                        self.crumbs.blob("send", blob)
                        self.queue.dispatch {
                            guard !self.ended else { return }
                            self.states.blobSent()
                            self.send(OLCallFrames.blob(blob, seq: self.nextSeq()))
                        }
                    })
                key.resetBytes(in: 0..<key.count) // the engine holds its own copy
                i.onRemoteAudioLevel = { [weak self] level in
                    self?.queue.dispatch { self?.onRemoteLevel(level) }
                }
                i.onState = { [weak self] st, rv, rm in
                    guard let self else { return }
                    self.remoteMuted = rm
                    self.remoteVideoActive = rv
                    self.connected = st == .connected
                    if st == .connected {
                        self.connectWatchdog?.cancel()
                        self.states.setState(.connected, reason: "tg-established")
                    }
                    self.crumbs.event("tg.state", st.rawValue, level: st == .failed ? "error" : "info")
                    self.emit(.state(st, remoteVideoActive: rv, remoteMuted: rm))
                    if st == .failed { self.end("tg-failed") }
                }
                instance = i
                i.makeIncomingVideoView { [weak self] v in if let v { self?.showRemote(v) } }
                if video { i.makeOutgoingVideoView { [weak self] v in if let v { self?.showLocal(v) } } }
                emit(.joined(isOutgoing: j.isOutgoing, version: version))
            } catch OLTgcallsError.noTurn {
                crumbs.event("tg", "no-turn", level: "error")
                end("no-turn")
            } catch {
                crumbs.event("tg", "create-failed:\(error)", level: "error")
                end("native-create-failed")
            }
        case let .blob(b):
            // The far side is here (a caller joins while the other phone still rings): only now
            // does the connect deadline start.
            if !peerSeen { peerSeen = true; armConnectWatchdog() }
            states.blobReceived()
            crumbs.blob("recv", b)
            instance?.receiveSignalingData(b)
        case let .bye(reason):
            end("bye:\(reason)")
        case let .error(e):
            crumbs.event("ws", "server-error:\(e)", level: "error")
            callLog.event("server_error", reason: OLCallLogTags.tag("server-error:\(e)"), detail: String("\(e)".prefix(60)))
            end("server-error")
        case .stats, .pong, .ignored:
            break
        }
    }

    private func end(_ reason: String) {
        guard !ended else { return }
        // Normal ends (local hangup, far side's bye) are not failures; everything else before Established is.
        let normal = reason == "local-hangup" || reason.hasPrefix("bye:")
        if states.state != .connected && !normal { states.fail(reason) }
        ended = true
        connectWatchdog?.cancel()
        pingTimer?.cancel()
        pingTimer = nil
        instance?.stop()
        instance = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio.end()
        DispatchQueue.main.async { self.videoTimer?.invalidate(); self.videoTimer = nil }
        crumbs.event("call", "ended:\(reason)")
        let wasConnected = states.state == .connected
        callLog.event("ended", reason: normal ? "normal" : wasConnected ? OLCallLogTags.tag("after-connect:\(reason)") : nil, detail: reason,
                      extra: ["connected": wasConnected, "blobsSent": states.blobsSent, "blobsReceived": states.blobsReceived])
        crumbs.flush()
        emit(.ended(reason))
    }

    /// Diagnostics: the far side's audio has been silent while they are not muted.
    private func onRemoteLevel(_ level: Float) {
        guard !ended else { return }
        if connected, level > inboundSilence.floor { markFlowing("audio") }
        if inboundSilence.sample(level: level, active: connected && !remoteMuted, now: Date().timeIntervalSince1970) == .reportSilent {
            crumbs.event("audio", "inbound-silent:\(Int(inboundSilence.window))s", level: "warning")
        }
    }

    /// Engine queue.
    private func markFlowing(_ source: String) {
        guard !flowing, !ended, connected else { return }
        flowing = true
        crumbs.event("call", "media-flowing:\(source)")
        callLog.event("media_flowing", reason: source, detail: nil)
        emit(.mediaFlowing(source: source))
    }

    private func armConnectWatchdog() {
        connectWatchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.queue.dispatch {
                guard let self, !self.ended, self.states.state != .connected else { return }
                self.end("connect-timeout") // -> failed with e.g. ice-stalled:connect-timeout
            }
        }
        connectWatchdog = w
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.connectTimeout, execute: w)
    }

    // MARK: video (main thread) — upright containers, 5 s stats, frozen-frame watchdog (t5450)

    private func showRemote(_ v: UIView) {
        let c = remoteView ?? makeContainer(side: "remote")
        remoteView = c
        c.setContent(v)
        emit(.remoteVideoView(c))
        startVideoTimer()
    }

    private func showLocal(_ v: UIView) {
        let c = localView ?? makeContainer(side: "local")
        localView = c
        c.setContent(v)
        emit(.localVideoView(c))
        startVideoTimer()
    }

    private func makeContainer(side: String) -> OLVideoView {
        let c = OLVideoView(frame: .zero)
        c.onOrientation = { [weak self] o in self?.crumbs.event("video.rotation", "\(side):\(o * 90)") }
        return c
    }

    private func startVideoTimer() {
        guard videoTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.videoTick() }
        RunLoop.main.add(t, forMode: .common)
        videoTimer = t
    }

    private func videoTick() {
        let r = remoteView?.takeFrames() ?? 0
        let l = localView?.takeFrames() ?? 0
        statsWindow.remote += r; statsWindow.local += l; statsWindow.ticks += 1
        if r > 0 { queue.dispatch { self.markFlowing("video") } }
        if statsWindow.ticks >= 5 {
            let w = statsWindow
            statsWindow = (0, 0, 0)
            crumbs.event("video", "stats:remoteFps=\(w.remote / w.ticks):localFps=\(w.local / w.ticks):remoteActive=\(remoteVideoActive):remoteRot=\((remoteView?.orientation ?? 0) * 90):localRot=\((localView?.orientation ?? 0) * 90):stalls=\(watchdog.stalls):reattaches=\(watchdog.reattaches)")
        }
        let stallsBefore = watchdog.stalls
        // t5457: watched only while the far side's video is on and media (audio) is flowing
        switch watchdog.tick(now: Date().timeIntervalSince1970, frames: r, watching: connected && flowing && remoteVideoActive && remoteView != nil) {
        case .none:
            break
        case let .requestKeyframe(ms):
            if watchdog.stalls != stallsBefore { queue.dispatch { self.logFreeze(ms) } }
            crumbs.event("video", "stall:remote:\(ms)ms:keyframe-request", level: "warning")
            queue.dispatch { guard !self.ended else { return }; self.send(OLCallFrames.keyframe(seq: self.nextSeq(), reason: "stall-\(ms)ms")) }
        case let .reattach(ms):
            crumbs.event("video", "stall:remote:\(ms)ms:reattach-renderer", level: "warning")
            queue.dispatch { self.instance?.makeIncomingVideoView { [weak self] v in if let v { self?.remoteView?.setContent(v) } } }
        case let .recovered(ms):
            crumbs.event("video", "recovered:remote:after=\(ms)ms")
        }
    }

    /// t5457: freeze start: when, the last rendered remote frame, and the media path state (tgcalls connection
    /// state; the path is TURN relay -> Pion, tgcalls exposes no candidate pair to the app).
    private func logFreeze(_ ms: Int) {
        let now = Date()
        let last = now.addingTimeInterval(-Double(ms) / 1000)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let detail = "at=\(f.string(from: now)):lastFrame=\(f.string(from: last)):tg=\(states.state.rawValue):path=relay-pion:ws=\(socket != nil ? "open" : "closed")"
        crumbs.event("video", "freeze:\(detail)", level: "warning")
        callLog.event("video_freeze", reason: "remote", detail: detail)
    }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent?(e) } }
}
