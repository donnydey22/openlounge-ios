// OLVideoWatchdog — frozen-remote-video detector (t5450). Pure logic, unit-tested; the engine feeds it once
// a second with how many remote frames were rendered since the last tick.
//
//   remote video active + call connected + no new frame for 2 s  -> requestKeyframe (Pion PLIs the sender)
//   still none at 5 s                                             -> reattach (fresh renderer on the same track)
//   frames again                                                  -> recovered (logged with the stall length)
//
// Audio is never touched. At most `maxReattach` re-attaches per call; keyframe requests at most every 2 s.
import Foundation

public struct OLVideoWatchdog {
    public enum Action: Equatable { case none, requestKeyframe(stalledMs: Int), reattach(stalledMs: Int), recovered(stalledMs: Int) }

    public static let keyframeAfter: TimeInterval = 2
    public static let reattachAfter: TimeInterval = 5
    public static let maxReattach = 3

    private var lastFrameAt: TimeInterval?
    private var lastKeyframeAt: TimeInterval?
    private var reattachedAt: TimeInterval?
    private var stalled = false
    public private(set) var reattaches = 0
    public private(set) var stalls = 0

    public init() {}

    /// - Parameters:
    ///   - frames: remote frames rendered since the previous tick
    ///   - watching: the far side's video is active and the call is connected (otherwise nothing is a stall)
    public mutating func tick(now: TimeInterval, frames: Int, watching: Bool) -> Action {
        guard watching else { lastFrameAt = nil; stalled = false; return .none }
        if frames > 0 {
            let since = lastFrameAt
            lastFrameAt = now
            if stalled, let s = since {
                stalled = false
                return .recovered(stalledMs: Int((now - s) * 1000))
            }
            stalled = false
            return .none
        }
        guard let last = lastFrameAt else { lastFrameAt = now; return .none } // arm: first watched tick
        let gap = now - last
        let ms = Int(gap * 1000)
        if gap >= Self.reattachAfter, reattaches < Self.maxReattach,
           reattachedAt.map({ now - $0 >= Self.reattachAfter }) ?? true {
            if !stalled { stalled = true; stalls += 1 }
            reattaches += 1
            reattachedAt = now
            return .reattach(stalledMs: ms)
        }
        if gap >= Self.keyframeAfter, lastKeyframeAt.map({ now - $0 >= Self.keyframeAfter }) ?? true {
            if !stalled { stalled = true; stalls += 1 }
            lastKeyframeAt = now
            return .requestKeyframe(stalledMs: ms)
        }
        return .none
    }
}

/// Upright rendering of an engine video view: tgcalls' VideoMetalView draws the raw camera buffer
/// (rotationOverride 0) and only reports the frame's rotation (0/1/2/3 = 0/90/180/270 degrees clockwise),
/// so the host must rotate the view. Pure math, unit-tested.
public enum OLVideoRotation {
    /// Clockwise angle in radians for UIKit's rotation transform.
    public static func angle(_ orientation: Int) -> Double {
        switch ((orientation % 4) + 4) % 4 {
        case 1: return Double.pi / 2
        case 2: return Double.pi
        case 3: return -Double.pi / 2
        default: return 0
        }
    }

    /// Bounds for the rotated content inside a container of `size`: width and height swap at 90/270.
    public static func contentSize(container w: Double, _ h: Double, orientation: Int) -> (Double, Double) {
        (((orientation % 4) + 4) % 4) % 2 == 1 ? (h, w) : (w, h)
    }
}
