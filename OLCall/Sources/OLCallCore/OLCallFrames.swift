// OLCallFrames — the phone <-> olcall Pion server WebSocket frames (wss://turn.openlounge.app/v1/call).
// Byte-for-byte the same frames Android's OlTgcallsEngine sends and reads:
//   C->S  join {token, traceId, surface:"tgcalls", platform, device, os, engine, version}
//   S->C  joined {callId, leg, key (b64, 256 B), isOutgoing, versions, iceServers}
//   C<->S blob {b64}        one engine signaling blob, unchanged both ways
//   S->C  stats {stats}     per-leg packet counters
//   C->S  hangup            S->C bye {reason}   S->C error {error}
//   C->S  ping              S->C pong
// The join token rides inside the join frame, never in the URL. Every client frame carries the
// client's own increasing "seq". Pure and pinned by Tests/OLCallCoreTests/Fixtures/call-frames.jsonl.
import Foundation

public enum OLCallFrames {
    public static let engine = "libtgcalls-ios/olcall"

    public struct Join {
        public var token: String, traceId: String, version: String, device: String, os: String
        public var engine = OLCallFrames.engine
        public init(token: String, traceId: String, version: String, device: String, os: String) {
            self.token = token; self.traceId = traceId; self.version = version; self.device = device; self.os = os
        }
    }

    public struct Joined {
        public let callId: String
        public let leg: String
        public let key: Data
        public let isOutgoing: Bool
        public let serverVersions: [String]
        /// RTCIceServer[] JSON from the joined frame (nil if absent). Parse with OLRtcServers.
        public let iceServers: Any?
    }

    public enum Inbound {
        case joined(Joined)
        case blob(Data)
        case stats([String: Any])
        case bye(String)
        case error(String)
        case pong
        case ignored(String)
    }

    public static func join(_ j: Join, seq: UInt64) -> [String: Any] {
        ["t": "join", "seq": seq, "token": j.token, "traceId": j.traceId, "surface": "tgcalls", "platform": "ios",
         "device": j.device, "os": j.os, "engine": j.engine, "version": j.version]
    }

    /// Standard base64 with padding (Go encoding/base64.StdEncoding on the server).
    public static func blob(_ data: Data, seq: UInt64) -> [String: Any] {
        ["t": "blob", "seq": seq, "b64": data.base64EncodedString()]
    }

    public static func hangup(seq: UInt64) -> [String: Any] { ["t": "hangup", "seq": seq] }
    public static func ping(seq: UInt64) -> [String: Any] { ["t": "ping", "seq": seq] }

    public static func encode(_ frame: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
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
}
