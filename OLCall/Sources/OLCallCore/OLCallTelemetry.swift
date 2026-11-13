// OLCallTelemetry — pure helpers for the "logs as armor" call-log fields (logging only; no call behavior).
//
//  - OLFpsSeries: 1 s video fps samples (in = rendered remote frames, out = local camera frames), shipped
//    in 5-sample batches ("video_fps") and summarized per call ("video_fps_summary": min/avg/p50).
//    Same signal Telegram's own stats use: frames rendered per second at the sink, not encoder targets.
//  - OLNetType: Wi-Fi / cellular / wired / other / none names for "network" / "network_change" events.
//  - OLAudioStatus: AVAudioSession / OSStatus codes rendered as the four-char code too ('!pri', 'cpri').
import Foundation

public struct OLFpsSeries {
    public private(set) var inSamples: [Int] = []
    public private(set) var outSamples: [Int] = []
    private var pendingIn: [Int] = []
    private var pendingOut: [Int] = []
    public static let batch = 5
    /// Cap so a very long call cannot grow the summary without bound (2 h of 1 s samples).
    public static let maxSamples = 7200

    public init() {}

    /// One 1 s sample. Returns a batch (in, out) every `batch` samples, else nil.
    public mutating func add(inFps: Int, outFps: Int) -> (in: [Int], out: [Int])? {
        if inSamples.count < Self.maxSamples { inSamples.append(inFps); outSamples.append(outFps) }
        pendingIn.append(inFps); pendingOut.append(outFps)
        guard pendingIn.count >= Self.batch else { return nil }
        defer { pendingIn = []; pendingOut = [] }
        return (pendingIn, pendingOut)
    }

    /// Unsent tail (end of call).
    public mutating func flush() -> (in: [Int], out: [Int])? {
        guard !pendingIn.isEmpty else { return nil }
        defer { pendingIn = []; pendingOut = [] }
        return (pendingIn, pendingOut)
    }

    public static func stats(_ s: [Int]) -> [String: Any] {
        guard !s.isEmpty else { return ["n": 0] }
        let sorted = s.sorted()
        let avg = Double(s.reduce(0, +)) / Double(s.count)
        return ["n": s.count, "min": sorted.first!, "max": sorted.last!, "avg": (avg * 10).rounded() / 10, "p50": sorted[(sorted.count - 1) / 2]]
    }

    /// Longest run of consecutive 1 s samples below `threshold` (seconds), for the in direction.
    public static func longestBelow(_ s: [Int], threshold: Int) -> Int {
        var best = 0, cur = 0
        for v in s { cur = v < threshold ? cur + 1 : 0; best = max(best, cur) }
        return best
    }

    /// Flat (the live call-log keeps only string/number/bool extras): inN/inMin/inMax/inAvg/inP50, out*, runs.
    public var summary: [String: Any] {
        var m: [String: Any] = ["inBelow20MaxRunSec": Self.longestBelow(inSamples, threshold: 20),
                                "outBelow20MaxRunSec": Self.longestBelow(outSamples, threshold: 20)]
        for (p, st) in [("in", Self.stats(inSamples)), ("out", Self.stats(outSamples))] {
            for (k, v) in st { m[p + OLLogExtra.cap(k)] = v }
        }
        return m
    }

    public static func csv(_ a: [Int]) -> String { a.map(String.init).joined(separator: ",") }
}

/// Extras the live call log keeps (server/calls/callLog.ts cleanExtra): <= 24 keys, values string (<= 160 chars) /
/// finite number / bool, key [\w.-]{1,32} and not secret-looking. Arrays -> CSV, nested dicts -> prefixed keys.
public enum OLLogExtra {
    public static let maxKeys = 24
    static let secretish = try! NSRegularExpression(pattern: "(token|secret|password|passwd|pwd|credential|key|sdp|blob|b64|ufrag|cookie|auth)", options: .caseInsensitive)

    static func cap(_ k: String) -> String { k.prefix(1).uppercased() + String(k.dropFirst()) }

    public static func isSecretish(_ k: String) -> Bool {
        secretish.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil
    }

    public static func liveSafe(_ x: [String: Any]) -> [String: Any] {
        var flat: [(String, Any)] = []
        func add(_ k: String, _ v: Any) {
            switch v {
            case let d as [String: Any]: for (k2, v2) in d.sorted(by: { $0.key < $1.key }) { add(k + cap(k2), v2) }
            case let a as [Int]: flat.append((k, OLFpsSeries.csv(a)))
            case let a as [Any]: flat.append((k, a.map { "\($0)" }.joined(separator: ",")))
            case let b as Bool: flat.append((k, b))
            case let i as Int: flat.append((k, i))
            case let d as Double: flat.append((k, d.isFinite ? d : 0))
            case let s as String: flat.append((k, String(s.prefix(160))))
            default: flat.append((k, "\(v)".prefix(160).description))
            }
        }
        for (k, v) in x.sorted(by: { $0.key < $1.key }) { add(k, v) }
        var out: [String: Any] = [:]
        for (k0, v) in flat {
            var k = String(k0.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }.prefix(32))
            if isSecretish(k) { k = "x_" + k.replacingOccurrences(of: "key", with: "k", options: .caseInsensitive) }
            guard !k.isEmpty, !isSecretish(k), out[k] == nil, out.count < maxKeys else { continue }
            out[k] = v
        }
        return out
    }
}

public enum OLNetType {
    public static func name(satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool) -> String {
        guard satisfied else { return "none" }
        if wifi { return "wifi" }
        if cellular { return "cellular" }
        if wired { return "wired" }
        return "other"
    }
}

public enum OLAudioStatus {
    /// Four-char code when printable (e.g. 561017449 -> "!pri"), else nil.
    public static func fourCC(_ code: Int) -> String? {
        let v = UInt32(truncatingIfNeeded: code)
        let bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    public static func describe(_ e: Error) -> [String: Any] {
        let n = e as NSError
        var d: [String: Any] = ["domain": n.domain, "code": n.code, "description": String(n.localizedDescription.prefix(160))]
        if let f = fourCC(n.code) { d["osstatus"] = f }
        return d
    }
}
