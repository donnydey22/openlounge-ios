// Incoming ring delivered by a PushKit VoIP push (server voipPayload, same fields as the FCM
// call_incoming data message) and the CallKit identity of a call.
import Foundation

public struct OLIncomingRing: Equatable {
    public let callId: String
    public let callerId: String
    public let callerName: String
    public let callerPhoto: String?
    public let video: Bool
    /// ms since 1970
    public let expiresAt: Double
    public let declineToken: String?

    public static func parse(_ p: [AnyHashable: Any]) -> OLIncomingRing? {
        guard p["type"] as? String == "call_incoming", let id = p["callId"] as? String, OLBridgeMessage.isCallId(id) else { return nil }
        let photo = (p["callerPhoto"] as? String).flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil }
        let exp = (p["expiresAt"] as? String).flatMap(Double.init) ?? (p["expiresAt"] as? Double) ?? 0
        let token = (p["declineToken"] as? String).flatMap { OLAppURL.matches($0, "^v1\\.[A-Za-z0-9_-]{8,500}\\.[A-Za-z0-9_-]{20,100}$") ? $0 : nil }
        let v = p["video"]
        return OLIncomingRing(callId: id, callerId: p["callerId"] as? String ?? "",
                              callerName: String((p["callerName"] as? String ?? "").prefix(80)),
                              callerPhoto: photo, video: (v as? String) == "1" || (v as? Bool) == true,
                              expiresAt: exp, declineToken: token)
    }

    public func expired(nowMs: Double) -> Bool { expiresAt > 0 && nowMs >= expiresAt }
}

public enum OLCallIdentity {
    /// Deterministic CallKit UUID for a call id (name-based, RFC 4122 version 5 layout), so a VoIP
    /// push, the page's call:incoming and a late cancel all address the same CallKit call.
    public static func uuid(for callId: String) -> UUID {
        var bytes = Array(OLSHA1.hash(Array("openlounge.call:\(callId)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// PushKit token as the server expects it (lower-case hex, 64-200 chars), or nil.
    public static func voipTokenHex(_ data: Data) -> String? {
        let s = data.map { String(format: "%02x", $0) }.joined()
        return OLAppURL.matches(s, "^[0-9a-f]{64,200}$") ? s : nil
    }
}

/// Minimal SHA-1 (identity derivation only, not security).
enum OLSHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var m = message
        let ml = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }
        for chunk in stride(from: 0, to: m.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                w[i] = (0..<4).reduce(0) { $0 << 8 | UInt32(m[chunk + i * 4 + $1]) }
            }
            for i in 16..<80 { let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = x << 1 | x >> 31 }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, b << 30 | b >> 2, a, t)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> (24 - UInt32($0) * 8)) & 0xff) } }
    }
}
