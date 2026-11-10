// OLSignalingRelay — the iPhone's WebSocket to the olcall Go/Pion server
// (wss://<host>/v1/call, docs/PROTOCOL.md, olcall/server/protocol.go Frame).
//
// tgcalls surface ("surface":"tgcalls"):
//   C->S  join {token, traceId, surface, platform, device, os, engine, version}
//   S->C  joined {callId, leg, key(b64, 256 B), isOutgoing, versions, iceServers?}
//         iceServers = coturn STUN + TURN with short-lived REST creds (never logged);
//         parsed by OLRtcServers, same rules as Android OlRtcServers.kt
//   The join token rides in the join frame (never in the URL), exactly as Android's
//   OlTgcallsEngine does and as olcall/server/server.go VerifyToken(join.Token) reads it.
//   C<->S blob {b64}        one tgcalls signaling blob, byte-identical both ways
//   S->C  stats {stats}     per-leg packet counters (every 2 s)
//   C->S  hangup            S->C bye {reason}   S->C error {error}
//   C->S  ping              S->C pong
// The offer/answer/ice/media of the call travel INSIDE the blobs as tgcalls
// signaling (InitialSetup = ICE ufrag/pwd + DTLS fingerprint, Candidates = ICE,
// NegotiateChannels = offer/answer, MediaState = media). The server decrypts and
// translates them (olcall/translator; olcall/sdpbridge maps the same messages to
// SDP). The JSON "offer"/"answer"/"ice"/"media" frames are the browser surface's
// and are never sent by phones.
//
// Every client frame carries the client's own increasing "seq" (breadcrumb join key).
// The encoders are pure and pinned by golden fixtures shared with the Go tests
// (Tests/OLTgcallsTests/Fixtures/ios-frames.jsonl <-> olcall/integration).
import Foundation

public final class OLSignalingRelay {
    public struct Joined {
        public let callId: String
        public let leg: String
        public let key: Data
        public let isOutgoing: Bool
        public let serverVersions: [String]
        /// Raw RTCIceServer[] JSON from the joined frame (nil if absent). Use OLRtcServers.select.
        public let iceServers: Any?
    }

    public struct JoinInfo {
        public var token: String, traceId: String, version: String, device: String, os: String
        public var engine = OLSignalingRelay.engine
        public init(token: String, traceId: String, version: String, device: String, os: String) {
            self.token = token; self.traceId = traceId; self.version = version; self.device = device; self.os = os
        }
    }

    public static let engine = "libtgcalls-ios/olcall"

    // MARK: pure frame codec (golden-tested)

    public static func joinFrame(_ j: JoinInfo, seq: UInt64) -> [String: Any] {
        ["t": "join", "seq": seq, "token": j.token, "traceId": j.traceId, "surface": "tgcalls", "platform": "ios",
         "device": j.device, "os": j.os, "engine": j.engine, "version": j.version]
    }

    /// Standard base64 with padding == Go encoding/base64.StdEncoding (server side).
    public static func blobFrame(_ blob: Data, seq: UInt64) -> [String: Any] {
        ["t": "blob", "seq": seq, "b64": blob.base64EncodedString()]
    }

    public static func hangupFrame(seq: UInt64) -> [String: Any] { ["t": "hangup", "seq": seq] }
    public static func pingFrame(seq: UInt64) -> [String: Any] { ["t": "ping", "seq": seq] }

    public enum Inbound {
        case joined(Joined)
        case blob(Data)
        case stats([String: Any])
        case bye(String)
        case error(String)
        case pong
        case ignored(String)
    }

    /// Decodes one server text frame. Invalid frames are errors, never crashes.
    public static func decode(_ text: String) -> Inbound {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let t = o["t"] as? String else { return .error("bad-frame") }
        switch t {
        case "joined":
            guard let b64 = o["key"] as? String, let key = Data(base64Encoded: b64), key.count == 256,
                  let out = o["isOutgoing"] as? Bool else { return .error("bad-joined") }
            return .joined(Joined(callId: o["callId"] as? String ?? "", leg: o["leg"] as? String ?? "", key: key,
                                  isOutgoing: out, serverVersions: o["versions"] as? [String] ?? [],
                                  iceServers: o["iceServers"]))
        case "blob":
            guard let b64 = o["b64"] as? String, let d = Data(base64Encoded: b64) else { return .error("bad-blob") }
            return .blob(d)
        case "stats": return .stats(o["stats"] as? [String: Any] ?? [:])
        case "bye": return .bye(o["reason"] as? String ?? "")
        case "error": return .error(o["error"] as? String ?? "")
        case "pong": return .pong
        default: return .ignored(t)
        }
    }

    // MARK: connection

    /// Delivered on `queue`.
    public var onInbound: ((Inbound) -> Void)?
    /// Delivered on `queue` once; reason like "ws-failure".
    public var onClosed: ((String) -> Void)?

    private let url: URL
    private let queue: OLCallQueue
    private let crumbs: OLBreadcrumbs
    private var task: URLSessionWebSocketTask?
    private var seq: UInt64 = 0
    private var closed = false
    private var pingTimer: DispatchSourceTimer?

    public init(url: URL, queue: OLCallQueue, crumbs: OLBreadcrumbs) {
        self.url = url
        self.queue = queue
        self.crumbs = crumbs
    }

    public func start(join: JoinInfo) {
        queue.dispatch {
            let t = URLSession.shared.webSocketTask(with: self.url)
            t.maximumMessageSize = 1 << 20  // = server ws.SetReadLimit
            self.task = t
            t.resume()
            self.crumbs.event("ws", "open")
            self.sendLocked(Self.joinFrame(join, seq: self.nextSeq()))
            self.receive()
            let timer = DispatchSource.makeTimerSource(queue: nil)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in self?.queue.dispatch { self?.sendLocked(Self.pingFrame(seq: self?.nextSeq() ?? 0)) } }
            timer.resume()
            self.pingTimer = timer
        }
    }

    /// One tgcalls blob (from OLTgcallsCall's sendSignalingData), unchanged.
    public func sendBlob(_ blob: Data) {
        crumbs.blob("send", "tg.blob", "signaling", blob)
        queue.dispatch { self.sendLocked(Self.blobFrame(blob, seq: self.nextSeq())) }
    }

    public func hangup() {
        queue.dispatch {
            self.sendLocked(Self.hangupFrame(seq: self.nextSeq()))
            self.close("local-hangup")
        }
    }

    public func close(_ reason: String) {
        queue.dispatch {
            guard !self.closed else { return }
            self.closed = true
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            self.crumbs.event("ws", "closed:\(reason)")
            self.onClosed?(reason)
        }
    }

    private func nextSeq() -> UInt64 { seq += 1; return seq }

    private func sendLocked(_ frame: [String: Any]) {
        guard !closed, let task, let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] err in
            if err != nil { self?.crumbs.event("ws", "send-failed", level: "error") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.crumbs.event("ws", "failure", level: "error")
                self.close("ws-failure")
            case let .success(msg):
                if case let .string(text) = msg {
                    let inbound = Self.decode(text)
                    if case let .blob(b) = inbound { self.crumbs.blob("recv", "tg.blob", "signaling", b) }
                    self.queue.dispatch { if !self.closed { self.onInbound?(inbound) } }
                }
                self.queue.dispatch { if !self.closed { self.receive() } }
            }
        }
    }
}
