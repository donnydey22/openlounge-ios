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

    public var summary: [String: Any] {
        ["in": Self.stats(inSamples), "out": Self.stats(outSamples),
         "inBelow20MaxRunSec": Self.longestBelow(inSamples, threshold: 20)]
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
