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
import Network
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
        /// Mid-call: the other party's media path is reconnecting (true) or back (false). Server `peer` frame.
        case peerReconnecting(Bool)
        /// Server-owned lifecycle (call:state). Observe only: never derive or write call state from it.
        case lifecycle(OLCallLifecycle)
    }

    /// Main queue.
    public var onEvent: ((Event) -> Void)?

    public let traceId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    public let version: String
    /// idle/joining/offering/answering/connected/failed; used on `queue`.
    public let states: OLCallStates
    /// No joined acknowledgement / no Established after peer arrival -> explicit failure.
    public static let joinAckTimeout: TimeInterval = 15
    public static let connectTimeout: TimeInterval = 45
    private static let maxResetRetries = 3

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
    private var joinAckWatchdog: DispatchWorkItem?
    private var connectWatchdog: DispatchWorkItem?
    private var joinAckReceived = false
    private var engineGeneration = 0
    private var resetAwaitingFrame = false
    private var peerSeen = false
    private var connected = false
    private var remoteMuted = false
    private let inboundSilence = OLSilenceWatchdog(window: 8, maxRecoveries: 0)
    private var remoteVideoActive = false
    /// Latest server-owned lifecycle snapshot (call:state); nil until the server sends one. Read-only mirror.
    public private(set) var lifecycle: OLCallLifecycle?
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
    /// Socket handover (queue): resume key/ids from "joined"; non-nil `resumer` while re-opening the socket.
    private var resumeKey: String?
    private var resumeCallId = ""
    private var resumeLeg = ""
    private var resumer: OLSignalingResume?
    private var resumeTask: URLSessionWebSocketTask?
    private var resumeScheduleWork: DispatchWorkItem?
    private var resumeAttemptWatchdog: DispatchWorkItem?
    private var resetRetryWork: DispatchWorkItem?
    private var queuedWhileResuming: [[String: Any]] = []
    /// Restart tgcalls on a path change or media silence after a signaling resume (b137).
    private var needsMediaReset = false
    private var resetInFlight = false
    private var resetCount = 0
    private var lastResetAt: TimeInterval?
    private var resumedAt: TimeInterval?
    private var silenceAfterResumeWatchdog: DispatchWorkItem?
    private var resetAckWatchdog: DispatchWorkItem?
    private var pathSettleWork: DispatchWorkItem?
    private var pathFrom: String?
    private var reconnectWatch: DispatchWorkItem?
    private var lastTgState: OLTgcallsInstance.State?
    private var resetRetries = 0
    private var localMuted = false
    private var localVideoOn = false
    /// Logging only (t5614u): network path + 1 s video fps series.
    private var pathMonitor: NWPathMonitor?
    private let netLock = NSLock()
    private var _netType: String?
    /// Read from main (fps), the audio queue (onLog) and the engine queue; written only by the path monitor.
    private var netType: String? {
        get { netLock.lock(); defer { netLock.unlock() }; return _netType }
        set { netLock.lock(); _netType = newValue; netLock.unlock() }
    }
    private var fps = OLFpsSeries()
    private let startedAt = Date()
    /// "push" when the app was not active as this call's media started (VoIP-push / CallKit wake), else "foreground".
    public var audioTrigger = "foreground"

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
        audio.trigger = audioTrigger
        audio.onLog = { [weak self] name, extra in
            guard let self else { return }
            var x = extra
            x["netType"] = self.netType ?? "unknown"
            self.callLog.event(name, reason: (extra["cause"] as? String) ?? (extra["what"] as? String) ?? (extra["via"] as? String), extra: OLLogExtra.liveSafe(x))
            if name == "audio_engine_stop" { self.callLog.kickUpload() }
        }
        startPathMonitor()
        localVideoOn = video
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
            let ack = DispatchWorkItem { [weak self] in
                self?.queue.dispatch {
                    guard let self, !self.ended, !self.joinAckReceived else { return }
                    self.end("join-ack-timeout")
                }
            }
            self.joinAckWatchdog = ack
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.joinAckTimeout, execute: ack)
            self.receive(on: t)
            let timer = DispatchSource.makeTimerSource(queue: nil)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                self?.queue.dispatch { guard let self else { return }; self.send(OLCallFrames.ping(seq: self.nextSeq())) }
            }
            timer.resume()
            self.pingTimer = timer
        }
    }

    public func setMuted(_ m: Bool) { queue.dispatch { self.localMuted = m; self.instance?.setMuted(m) } }

    /// Camera on/off. Call only after the camera permission gate passed.
    public func setVideoEnabled(_ on: Bool) {
        queue.dispatch {
            self.localVideoOn = on
            guard let i = self.instance else { return }
            i.setVideoEnabled(on)
            if on { i.makeOutgoingVideoView { [weak self] v in if let v { self?.showLocal(v) } } }
        }
    }

    public func switchCamera(front: Bool) { queue.dispatch { self.instance?.switchCamera(front: front) } }
    public func setSpeaker(_ on: Bool) { audio.setSpeaker(on) }

    /// Synchronously admits work onto the existing bounded reset owner. No media engine is replaced here.
    public func restartIce() -> Bool {
        queue.sync {
            guard !ended, states.state == .connected, socket != nil, resumer == nil,
                  OLMediaReset.allowed(connected: true, inFlight: resetInFlight, ended: ended,
                                       count: resetCount, last: lastResetAt,
                                       now: Date().timeIntervalSince1970) else { return false }
            beginMediaReset(reason: "restart-ice")
            return true
        }
    }

    public func hangup() {
        queue.dispatch {
            guard !self.ended else { return }
            self.send(OLCallFrames.hangup(seq: self.nextSeq()))
            self.end("local-hangup")
        }
    }

    public func callKitDidActivate(_ s: AVAudioSession) { audio.callKitDidActivate(s) }
    /// iOS ring calls (link joins never use CallKit): CallKit owns the audio session and didDeactivate means it tore the
    /// session down, so the media died. This engine, the only writer of this leg's frames, tells the call server at
    /// once, with no page in between (Apple DTS / Speakerbox: the call provider owns hang-up). The server's FSM is the
    /// single writer of call:state; the backend relays it to the page and the other leg.
    ///   - CallKit no longer holds the call, or tgcalls never got going / failed  -> Ended: hangup frame.
    ///   - CallKit still holds the call and tgcalls was connected / reconnecting   -> Reconnecting: reset-leg frame (the
    ///     existing media-reset ladder; the server's 20 s ceiling ends it if it never comes back). Audio returns on the
    ///     next didActivate.
    /// The session itself is never deactivated here (no setActive(false) on a CallKit-owned session).
    public func callKitDidDeactivate(_ s: AVAudioSession, callKitHoldsCall: Bool) {
        audio.callKitDidDeactivate(s)
        queue.dispatch {
            guard !self.ended else { return }
            let tg = self.lastTgState
            let live = tg == .connected || tg == .reconnecting
            if callKitHoldsCall && live {
                self.logAppEvent("callkit_deactivated", ["map": "reconnecting", "tg": tg?.rawValue ?? "none"])
                self.beginMediaReset(reason: "callkit-deactivated")
            } else {
                self.logAppEvent("callkit_deactivated", ["map": "ended", "tg": tg?.rawValue ?? "none", "callkitHolds": callKitHoldsCall])
                self.send(OLCallFrames.hangup(seq: self.nextSeq()))
                self.end("local-hangup")
            }
        }
    }

    // MARK: socket (queue)

    private func nextSeq() -> UInt64 { seq += 1; return seq }

    private func send(_ frame: [String: Any]) {
        guard !ended else { return }
        if socket == nil, resumer != nil, let t = frame["t"] as? String, t == "blob" || t == "keyframe" {
            // Socket handover in progress: keep tgcalls' signaling (e.g. its new-network candidates) for the new socket.
            queuedWhileResuming.append(frame)
            if queuedWhileResuming.count > OLSignalingResume.maxQueued { queuedWhileResuming.removeFirst() }
            return
        }
        guard let socket, let text = OLCallFrames.encode(frame) else { return }
        socket.send(.string(text)) { [weak self] err in
            if err != nil { self?.crumbs.event("ws", "send-failed", level: "error") }
        }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.dispatch {
                guard !self.ended, self.socket === t else { return } // a replaced (handed-over) socket is ignored
                switch result {
                case let .failure(err):
                    let code = t.closeCode
                    let reason = code != .invalid ? "ws-closed:\(code.rawValue)" : "ws-failure"
                    self.crumbs.event("ws", "failure:\((err as NSError).code):close=\(code.rawValue)", level: "error")
                    // A finite close code is still a transient transport loss. Resume the same leg whenever
                    // the server gave us a key; only pre-media/keyless calls retain the old terminal behavior.
                    if OLSignalingResume.shouldResume(connected: self.states.state == .connected,
                                                      hasKey: self.resumeKey != nil, ended: self.ended) {
                        self.beginResume()
                    } else {
                        self.end(reason)
                    }
                case let .success(msg):
                    if case let .string(text) = msg { self.onFrame(OLCallFrames.decode(text)) }
                    if !self.ended { self.receive(on: t) }
                }
            }
        }
    }

    // MARK: socket handover (queue) — call 11c994c9: the socket died on Wi-Fi -> cellular and the call ended
    // although tgcalls (which re-gathers on the new network) was fine. Keep tgcalls, re-open the socket, send
    // {t:"resume"} with the joined key; the server rebinds the same leg. Not resumed in 18 s -> end as before.

    private func beginResume() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        resumer = OLSignalingResume(now: Date().timeIntervalSince1970)
        crumbs.event("ws", "resume:start", level: "warning")
        callLog.event("ws_resume", reason: "start", extra: ["netType": netType ?? "unknown"])
        scheduleResumeAttempt()
    }

    private func scheduleResumeAttempt() {
        guard !ended, var r = resumer else { return }
        guard let d = r.next(now: Date().timeIntervalSince1970) else {
            crumbs.event("ws", "resume:gave-up:attempts=\(r.attempts)", level: "error")
            callLog.event("ws_resume", reason: "gave_up", detail: "attempts=\(r.attempts)",
                          extra: ["outcome": "failed", "gapMs": Int((Date().timeIntervalSince1970 - r.startedAt) * 1000), "netType": netType ?? "unknown"])
            resumer = nil
            end("ws-failure")
            return
        }
        resumer = r
        let work = DispatchWorkItem { [weak self] in
            self?.queue.dispatch { self?.resumeAttempt() }
        }
        resumeScheduleWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + d, execute: work)
    }

    private func resumeAttempt() {
        guard !ended, resumer != nil, socket == nil, resumeTask == nil, let key = resumeKey else { return }
        let t = URLSession.shared.webSocketTask(with: media.url)
        t.maximumMessageSize = 1 << 20
        resumeTask = t
        t.resume()
        if let text = OLCallFrames.encode(OLCallFrames.resume(callId: resumeCallId, leg: resumeLeg, key: key, traceId: traceId, seq: nextSeq())) {
            t.send(.string(text)) { _ in }
        }
        let w = DispatchWorkItem { [weak self] in
            self?.queue.dispatch {
                guard let self, self.resumeTask === t else { return }
                self.resumeTask = nil
                t.cancel(with: .goingAway, reason: nil)
                self.scheduleResumeAttempt()
            }
        }
        resumeAttemptWatchdog = w
        DispatchQueue.global().asyncAfter(deadline: .now() + OLSignalingResume.attemptTimeout, execute: w)
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.dispatch {
                guard !self.ended, self.resumeTask === t else { return }
                self.resumeAttemptWatchdog?.cancel()
                self.resumeTask = nil
                guard case let .success(msg) = result, case let .string(text) = msg else {
                    t.cancel(with: .goingAway, reason: nil)
                    self.scheduleResumeAttempt() // no network yet: retry inside the window
                    return
                }
                switch OLCallFrames.decode(text) {
                case .resumed:
                    let r = self.resumer
                    self.resumer = nil
                    self.socket = t
                    let gapMs = Int((Date().timeIntervalSince1970 - (r?.startedAt ?? 0)) * 1000)
                    self.crumbs.event("ws", "resumed:attempts=\(r?.attempts ?? 0):gapMs=\(gapMs)")
                    self.callLog.event("ws_resume", reason: "resumed", detail: "attempts=\(r?.attempts ?? 0)",
                                       extra: ["outcome": "resumed", "gapMs": gapMs, "netType": self.netType ?? "unknown"])
                    let q = self.queuedWhileResuming
                    self.queuedWhileResuming = []
                    for f in q { self.send(f) }
                    self.receive(on: t)
                    self.onSignalingResumed()
                case let .bye(reason):
                    t.cancel(with: .normalClosure, reason: nil)
                    self.end("bye:\(reason)")
                default:
                    // refused (unknown call / key): the leg is gone, end exactly as before
                    t.cancel(with: .normalClosure, reason: nil)
                    self.crumbs.event("ws", "resume:refused", level: "error")
                    let gap = Int((Date().timeIntervalSince1970 - (self.resumer?.startedAt ?? Date().timeIntervalSince1970)) * 1000)
                    self.callLog.event("ws_resume", reason: "refused", extra: ["outcome": "failed", "gapMs": gap, "netType": self.netType ?? "unknown"])
                    self.resumer = nil
                    self.end("ws-failure")
                }
            }
        }
    }

    private func onFrame(_ f: OLCallFrames.Inbound) {
        switch f {
        case let .joined(j):
            guard !joinAckReceived else {
                crumbs.event("ws", "duplicate-joined-ignored", level: "warning")
                return
            }
            joinAckReceived = true
            joinAckWatchdog?.cancel(); joinAckWatchdog = nil
            crumbs.callId = j.callId
            crumbs.leg = j.leg
            resumeKey = j.resume
            resumeCallId = j.callId
            resumeLeg = j.leg
            states.callId = j.callId
            states.setState(j.isOutgoing ? .offering : .answering, reason: "joined")
            crumbs.event("tg", "joined:outgoing=\(j.isOutgoing):version=\(version)")
            if !j.serverVersions.isEmpty && !j.serverVersions.contains(version) {
                crumbs.event("tg", "server-lacks-version:\(version)", level: "error")
                end("version-mismatch")
                return
            }
            startEngine(from: j, isInitialJoin: true)
        case let .blob(b):
            // The far side is here (a caller joins while the other phone still rings): only now
            // does the connect deadline start.
            if !peerSeen { peerSeen = true; armConnectWatchdog() }
            states.blobReceived()
            crumbs.blob("recv", b)
            instance?.receiveSignalingData(b)
        case let .bye(reason):
            crumbs.event("tg", "bye:\(reason)")
            end("bye:\(reason)")
        case let .peer(p):
            crumbs.event("tg", "peer:\(p)")
            if p == "reconnecting" || p == "connected" {
                let on = p == "reconnecting"
                emit(.peerReconnecting(on))
            }
        case let .legReset(j):
            guard resetInFlight, resetAwaitingFrame,
                  j.callId == resumeCallId, j.leg == resumeLeg else {
                crumbs.event("ws", "stale-leg-reset-ignored", level: "warning")
                return
            }
            resetAwaitingFrame = false
            resetAckWatchdog?.cancel(); resetAckWatchdog = nil
            if let rotated = j.resume { resumeKey = rotated }
            startEngine(from: j, isInitialJoin: false)
        case let .mediaLost(reason):
            crumbs.event("tg", "server-media-lost:\(reason)", level: "warning")
            if !resetInFlight { beginMediaReset(reason: "server-media-lost") } else { needsMediaReset = true }
        case let .error(e):
            if e == "call-ended" {
                // The other side ended (or cancelled) before this join arrived: a normal end, not a failure.
                crumbs.event("tg", "server:call-ended")
                end("bye:call-ended")
                break
            }
            if e == "reset-limited" || e == "reset-unsupported" || e == "translator" {
                crumbs.event("tg", "media-reset:\(e)", level: "warning")
                resetAckWatchdog?.cancel(); resetAckWatchdog = nil
                resetInFlight = false
                resetAwaitingFrame = false
                // The preceding engine instance was stopped. Every refusal ends in a bounded successor or explicit termination.
                if e == "reset-unsupported" {
                    end("reset-unsupported")
                } else if instance == nil {
                    scheduleResetRetry("retry-\(e)")
                }
                break
            }
            crumbs.event("ws", "server-error:\(e)", level: "error")
            callLog.event("server_error", reason: OLCallLogTags.tag("server-error:\(e)"), detail: String("\(e)".prefix(60)))
            end("server-error")
        case let .callState(l):
            // The server is the single writer of the call lifecycle (olcall states.go); pass it through untouched.
            if OLCallLifecycle.newer(lifecycle, l) {
                lifecycle = l
                emit(.lifecycle(l))
            }
        case .stats:
            break // server diagnostics; iOS reads its own engine stats
        case .pong:
            break // keepalive reply; the ping's job is done once the socket delivered it
        case .resumed:
            break // only meaningful on the resume socket, handled in the resume receive path
        case let .ignored(t), let .unknown(t):
            // Forward compatibility: additive future frames are observable but never fatal. Malformed known
            // frames still arrive as .error("bad-...") and retain strict handling above.
            crumbs.event("ws", "unknown-frame-ignored:\(t)", level: "warning")
            callLog.event("unknown_frame_ignored", reason: OLCallLogTags.tag("unknown-frame:\(t)"), detail: String(t.prefix(60)))
        }
    }

    private func end(_ reason: String) {
        guard !ended else { return }
        pathSettleWork?.cancel(); reconnectWatch?.cancel()
        // Normal ends (local hangup, far side's bye) are not failures; everything else before Established is.
        let normal = reason == "local-hangup" || reason.hasPrefix("bye:")
        if states.state != .connected && !normal { states.fail(reason) }
        ended = true
        joinAckWatchdog?.cancel(); joinAckWatchdog = nil
        connectWatchdog?.cancel(); connectWatchdog = nil
        pingTimer?.cancel()
        pingTimer = nil
        resumeScheduleWork?.cancel(); resumeScheduleWork = nil
        resumeAttemptWatchdog?.cancel(); resumeAttemptWatchdog = nil
        silenceAfterResumeWatchdog?.cancel(); silenceAfterResumeWatchdog = nil
        resetAckWatchdog?.cancel(); resetAckWatchdog = nil
        resetRetryWork?.cancel(); resetRetryWork = nil
        pathSettleWork?.cancel(); pathSettleWork = nil
        reconnectWatch?.cancel(); reconnectWatch = nil
        resumeTask?.cancel(with: .normalClosure, reason: nil)
        resumeTask = nil
        resumer = nil
        queuedWhileResuming = []
        resumeKey = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        engineGeneration += 1
        resetAwaitingFrame = false
        instance?.stop()
        instance = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio.onActiveChanged = nil
        audio.onRouteChanged = nil
        audio.onLog = nil
        audio.end()
        DispatchQueue.main.async {
            self.videoTimer?.invalidate(); self.videoTimer = nil
            self.logFpsTail()
            self.callLog.kickUpload()
        }
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
        silenceAfterResumeWatchdog?.cancel()
        resumedAt = nil
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
        if connected, let b = fps.add(inFps: r, outFps: l) {
            callLog.event("video_fps", extra: ["in": OLFpsSeries.csv(b.in), "out": OLFpsSeries.csv(b.out), "remoteActive": remoteVideoActive, "netType": netType ?? "unknown"])
        }
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

    // MARK: logs as armor (t5614u) — logging only, no call behavior

    /// App-layer facts (CallKit ordering before the engine existed, replay decision) into this call's log.
    public func logAppEvent(_ name: String, _ extra: [String: Any]) {
        var x = extra
        x["netType"] = netType ?? "unknown"
        callLog.event(name, extra: OLLogExtra.liveSafe(x))
    }

    /// Main thread, once at end: unsent fps tail + the per-call summary (min/avg/p50 each way).
    private func logFpsTail() {
        if let b = fps.flush() {
            callLog.event("video_fps", extra: ["in": OLFpsSeries.csv(b.in), "out": OLFpsSeries.csv(b.out), "remoteActive": remoteVideoActive, "netType": netType ?? "unknown"])
        }
        guard !fps.inSamples.isEmpty else { return }
        var x = fps.summary
        x["netType"] = netType ?? "unknown"
        x["video"] = video
        callLog.event("video_fps_summary", extra: OLLogExtra.liveSafe(x))
    }


    /// Engine queue. Builds (or rebuilds) the tgcalls instance from a joined / leg-reset frame.
    private func startEngine(from j: OLCallFrames.Joined, isInitialJoin: Bool) {
        if !j.serverVersions.isEmpty && !j.serverVersions.contains(version) {
            crumbs.event("tg", "server-lacks-version:\(version)", level: "error")
            end("version-mismatch")
            return
        }
        engineGeneration += 1
        let generation = engineGeneration
        let replaced = instance
        instance = nil
        replaced?.stop() // an old native handle must never survive a leg-reset replacement
        let rtc = OLRtcServers.fromIceServers(j.iceServers)
        crumbs.event("tg", "rtc-servers:" + OLRtcServers.summary(rtc))
        callLog.turnServers = rtc.filter { $0.isTurn }.count
        callLog.event("rtc_servers", extra: ["turnServers": rtc.filter { $0.isTurn }.count, "stunServers": rtc.filter { !$0.isTurn }.count])
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            var key = j.key
            let i = try OLTgcallsInstance(
                config: .init(version: version, key: key, isOutgoing: j.isOutgoing, video: isInitialJoin ? video : localVideoOn,
                              logDirectory: caches, traceId: traceId, rtcServers: rtc),
                queue: queue, audioDevice: audio,
                sendSignalingData: { [weak self] blob in
                    guard let self else { return }
                    self.crumbs.blob("send", blob)
                    self.queue.dispatch {
                        guard !self.ended, self.engineGeneration == generation else { return }
                        self.states.blobSent()
                        self.send(OLCallFrames.blob(blob, seq: self.nextSeq()))
                    }
                })
            key.resetBytes(in: 0..<key.count) // the engine holds its own copy
            i.onRemoteAudioLevel = { [weak self] level in
                self?.queue.dispatch {
                    guard let self, self.engineGeneration == generation else { return }
                    self.onRemoteLevel(level)
                }
            }
            i.onState = { [weak self] st, rv, rm in
                guard let self, !self.ended, self.engineGeneration == generation else { return }
                let midCall = self.states.state == .connected
                self.remoteMuted = rm
                self.remoteVideoActive = rv
                self.connected = st == .connected
                if st == .connected {
                    self.connectWatchdog?.cancel()
                    self.states.setState(.connected, reason: "tg-established")
                    self.resetInFlight = false
                    self.resetAwaitingFrame = false
                    self.resetRetryWork?.cancel(); self.resetRetryWork = nil
                    self.reconnectWatch?.cancel(); self.resetRetries = 0
                }
                self.lastTgState = st
                if midCall, st == .reconnecting, !self.resetInFlight { self.armReconnectWatch() }
                if st == .failed {
                    if midCall {
                        self.crumbs.event("tg.state", "failed:restarting", level: "error")
                        if self.resetInFlight {
                            // The replacement itself failed: it is not a successor. Stop it and enter the
                            // same bounded retry-or-terminate ladder as a refused/timed-out reset.
                            self.resetInFlight = false
                            self.resetAwaitingFrame = false
                            self.resetAckWatchdog?.cancel(); self.resetAckWatchdog = nil
                            self.engineGeneration += 1
                            self.instance?.stop()
                            self.instance = nil
                            self.scheduleResetRetry("retry-replacement-failed")
                        } else {
                            self.beginMediaReset(reason: "tg-failed")
                        }
                    } else {
                        self.crumbs.event("tg.state", "failed:initial", level: "error")
                        self.end("tg-failed")
                    }
                    return
                }
                self.crumbs.event("tg.state", st.rawValue, level: "info")
                self.emit(.state(st, remoteVideoActive: rv, remoteMuted: rm))
            }
            instance = i
            if localMuted { i.setMuted(true) }
            i.makeIncomingVideoView { [weak self] v in
                guard let self, self.engineGeneration == generation, let v else { return }
                self.showRemote(v)
            }
            if isInitialJoin ? video : localVideoOn {
                i.setVideoEnabled(true)
                i.makeOutgoingVideoView { [weak self] v in
                    guard let self, self.engineGeneration == generation, let v else { return }
                    self.showLocal(v)
                }
            }
            if isInitialJoin {
                emit(.joined(isOutgoing: j.isOutgoing, version: version))
            } else {
                resetAckWatchdog?.cancel()
                peerSeen = true
                armConnectWatchdog()
                crumbs.event("tg", "media-reset:engine-started")
            }
        } catch OLTgcallsError.noTurn {
            crumbs.event("tg", "no-turn", level: "error")
            resetInFlight = false
            end("no-turn")
        } catch {
            crumbs.event("tg", "create-failed:\(error)", level: "error")
            resetInFlight = false
            end("native-create-failed")
        }
    }

    /// Path flip mid-call (138, Nov 15 night: dual-connected phones move their default path while the previous one
    /// stays up a while and then dies). After the flip settles, move signaling to the new path (resume on a fresh
    /// socket) and restart the engine there, instead of waiting for the previous socket to die.
    private func maybeResetOnPath(from: String, to: String) {
        if pathFrom == nil { pathFrom = from }
        pathSettleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.queue.dispatch { self?.settlePath(to: to) }
        }
        pathSettleWork = w
        DispatchQueue.global().asyncAfter(deadline: .now() + OLMediaReset.pathSettle, execute: w)
    }

    private func settlePath(to: String) {
        guard let from = pathFrom else { return }
        pathFrom = nil
        guard !ended, OLMediaReset.pathChange(from, to), states.state == .connected else { return }
        crumbs.event("net", "handover:\(from)->\(to)", level: "warning")
        needsMediaReset = true
        if resumeKey != nil, resumer == nil {
            beginResume() // cancels the current socket; onSignalingResumed restarts media on the new path
        } else if socket != nil, resumer == nil {
            beginMediaReset(reason: "path:\(from)->\(to)")
        }
    }

    private func scheduleResetRetry(_ reason: String) {
        guard !ended else { return }
        guard resetRetries < Self.maxResetRetries else { end("reset-exhausted"); return }
        resetRetries += 1
        resetRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.queue.dispatch {
                guard let self, !self.ended, !self.resetInFlight, self.instance == nil else { return }
                self.beginMediaReset(reason: reason)
            }
        }
        resetRetryWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + max(2.5, OLMediaReset.cooldown), execute: work)
    }

    private func armReconnectWatch() {
        reconnectWatch?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.queue.dispatch {
                guard let self, !self.ended, self.lastTgState == .reconnecting else { return }
                if OLMediaReset.allowed(connected: self.states.state == .connected, inFlight: self.resetInFlight,
                                        ended: self.ended, count: self.resetCount, last: self.lastResetAt,
                                        now: Date().timeIntervalSince1970) {
                    self.beginMediaReset(reason: "tg-reconnecting")
                } else if self.states.state == .connected {
                    self.armReconnectWatch()
                }
            }
        }
        reconnectWatch = w
        DispatchQueue.global().asyncAfter(deadline: .now() + OLMediaReset.reconnectingReset, execute: w)
    }

    private func onSignalingResumed() {
        flowing = false
        resumedAt = Date().timeIntervalSince1970
        if needsMediaReset, states.state == .connected, socket != nil {
            beginMediaReset(reason: "after-resume")
        } else {
            armSilenceAfterResume()
        }
    }

    private func armSilenceAfterResume() {
        silenceAfterResumeWatchdog?.cancel()
        let started = resumedAt ?? Date().timeIntervalSince1970
        resumedAt = started
        let w = DispatchWorkItem { [weak self] in
            self?.queue.dispatch {
                guard let self, !self.ended else { return }
                let now = Date().timeIntervalSince1970
                if OLMediaReset.shouldResetOnSilence(resumedAt: self.resumedAt, flowing: self.flowing,
                                                     remoteMuted: self.remoteMuted,
                                                     connected: self.states.state == .connected, inFlight: self.resetInFlight,
                                                     ended: self.ended, count: self.resetCount, last: self.lastResetAt, now: now) {
                    self.beginMediaReset(reason: "silence-after-resume")
                }
            }
        }
        silenceAfterResumeWatchdog = w
        DispatchQueue.global().asyncAfter(deadline: .now() + OLMediaReset.silenceAfterResume, execute: w)
    }

    /// Stop this peer's tgcalls instance and ask the server to reset only this slot's translator.
    private func beginMediaReset(reason: String) {
        guard !ended else { return }
        guard !resetInFlight, socket != nil, resumer == nil else {
            needsMediaReset = true
            return
        }
        guard states.state == .connected else { return }
        guard resetCount < OLMediaReset.maxPerCall else { end("reset-exhausted"); return }
        resetInFlight = true
        resetAwaitingFrame = true
        needsMediaReset = false
        resetCount += 1
        lastResetAt = Date().timeIntervalSince1970
        flowing = false
        resumedAt = nil
        silenceAfterResumeWatchdog?.cancel()
        crumbs.event("tg", "media-reset:\(reason)", level: "warning")
        callLog.event("media_reset", reason: reason, extra: ["count": resetCount, "netType": netType ?? "unknown"])
        engineGeneration += 1
        let old = instance
        instance = nil
        old?.stop()
        send(OLCallFrames.resetLeg(seq: nextSeq()))
        let w = DispatchWorkItem { [weak self] in
            self?.queue.dispatch {
                guard let self, self.resetInFlight, !self.ended else { return }
                self.resetInFlight = false
                self.resetAwaitingFrame = false
                self.crumbs.event("tg", "media-reset:timeout", level: "error")
                // No half-created replacement may linger while a retry is scheduled.
                self.engineGeneration += 1
                self.instance?.stop()
                self.instance = nil
                self.scheduleResetRetry("retry-timeout")
            }
        }
        resetAckWatchdog = w
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: w)
    }

    /// Network type for every call-log line; "network" once, then "network_change" from/to. Like Telegram's
    /// setNetworkType (VoIPService.updateNetworkType). A wifi <-> cellular change now also restarts the engine.
    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let t = OLNetType.name(satisfied: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi),
                                   cellular: path.usesInterfaceType(.cellular), wired: path.usesInterfaceType(.wiredEthernet))
            self?.queue.dispatch {
                guard let self, !self.ended else { return }
                let from = self.netType
                guard from != t else { return }
                self.netType = t
                let ms = Int(Date().timeIntervalSince(self.startedAt) * 1000)
                if let from {
                    self.crumbs.event("net", "change:\(from)->\(t)", level: "warning")
                    self.callLog.event("network_change", reason: "\(from)->\(t)",
                                       extra: ["from": from, "to": t, "msSinceStart": ms, "connected": self.states.state == .connected,
                                               "wsUp": self.socket != nil, "resuming": self.resumer != nil])
                    self.maybeResetOnPath(from: from, to: t)
                } else {
                    self.callLog.event("network", reason: t, extra: ["type": t, "msSinceStart": ms])
                }
            }
        }
        m.start(queue: DispatchQueue(label: "ol.call.net"))
        pathMonitor = m
    }
}
