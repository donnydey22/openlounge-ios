@testable import OLCallCore
import XCTest

final class OLVideoWatchdogTests: XCTestCase {
    func testKeyframeThenReattachThenRecovered() {
        var w = OLVideoWatchdog()
        XCTAssertEqual(w.tick(now: 0, frames: 5, watching: true), .none)
        XCTAssertEqual(w.tick(now: 1, frames: 0, watching: true), .none)
        XCTAssertEqual(w.tick(now: 2, frames: 0, watching: true), .requestKeyframe(stalledMs: 2000))
        XCTAssertEqual(w.tick(now: 3, frames: 0, watching: true), .none)
        XCTAssertEqual(w.tick(now: 4, frames: 0, watching: true), .requestKeyframe(stalledMs: 4000))
        XCTAssertEqual(w.tick(now: 5, frames: 0, watching: true), .reattach(stalledMs: 5000))
        XCTAssertEqual(w.tick(now: 6, frames: 0, watching: true), .requestKeyframe(stalledMs: 6000))
        XCTAssertEqual(w.tick(now: 7, frames: 3, watching: true), .recovered(stalledMs: 7000))
        XCTAssertEqual(w.tick(now: 8, frames: 3, watching: true), .none)
        XCTAssertEqual(w.stalls, 1)
        XCTAssertEqual(w.reattaches, 1)
    }

    func testNotWatchingIsNeverAStall() {
        var w = OLVideoWatchdog()
        XCTAssertEqual(w.tick(now: 0, frames: 5, watching: true), .none)
        // far side turned the camera off (or audio-only): no frames is expected
        for t in 1...20 { XCTAssertEqual(w.tick(now: Double(t), frames: 0, watching: false), .none) }
        // watching again: re-arms instead of counting the off period as a stall
        XCTAssertEqual(w.tick(now: 21, frames: 0, watching: true), .none)
        XCTAssertEqual(w.tick(now: 22, frames: 0, watching: true), .none)
        XCTAssertEqual(w.tick(now: 23, frames: 0, watching: true), .requestKeyframe(stalledMs: 2000))
    }

    func testReattachIsCapped() {
        var w = OLVideoWatchdog()
        _ = w.tick(now: 0, frames: 1, watching: true)
        var reattaches = 0
        for t in 1...120 {
            if case .reattach = w.tick(now: Double(t), frames: 0, watching: true) { reattaches += 1 }
        }
        XCTAssertEqual(reattaches, OLVideoWatchdog.maxReattach)
    }

    func testRotationMath() {
        XCTAssertEqual(OLVideoRotation.angle(0), 0)
        XCTAssertEqual(OLVideoRotation.angle(1), Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(OLVideoRotation.angle(2), Double.pi, accuracy: 1e-9)
        XCTAssertEqual(OLVideoRotation.angle(3), -Double.pi / 2, accuracy: 1e-9)
        let (w, h) = OLVideoRotation.contentSize(container: 96, 136, orientation: 1)
        XCTAssertEqual(w, 136); XCTAssertEqual(h, 96)
        let (w0, h0) = OLVideoRotation.contentSize(container: 96, 136, orientation: 2)
        XCTAssertEqual(w0, 96); XCTAssertEqual(h0, 136)
    }

    func testKeyframeFrame() {
        let f = OLCallFrames.keyframe(seq: 7, reason: "stall-2000ms")
        XCTAssertEqual(f["t"] as? String, "keyframe")
        XCTAssertEqual(f["reason"] as? String, "stall-2000ms")
    }
}
