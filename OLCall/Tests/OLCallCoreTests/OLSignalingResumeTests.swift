import XCTest
@testable import OLCallCore

final class OLSignalingResumeTests: XCTestCase {
    func testOnlyConnectedCallsWithKeyResume() {
        XCTAssertTrue(OLSignalingResume.shouldResume(connected: true, hasKey: true, ended: false))
        XCTAssertFalse(OLSignalingResume.shouldResume(connected: false, hasKey: true, ended: false)) // before media: unchanged
        XCTAssertFalse(OLSignalingResume.shouldResume(connected: true, hasKey: false, ended: false)) // old server: unchanged
        XCTAssertFalse(OLSignalingResume.shouldResume(connected: true, hasKey: true, ended: true))
    }

    func testBackoffAndWindow() {
        XCTAssertEqual(OLSignalingResume.delay(attempt: 0), 0.25)
        XCTAssertEqual(OLSignalingResume.delay(attempt: 2), 1)
        XCTAssertEqual(OLSignalingResume.delay(attempt: 9), 2)
        var r = OLSignalingResume(now: 100)
        var t = 100.0
        while let d = r.next(now: t) { t += d + OLSignalingResume.attemptTimeout }
        XCTAssertLessThan(t, 100 + OLSignalingResume.window + OLSignalingResume.attemptTimeout + 2)
        XCTAssertGreaterThanOrEqual(r.attempts, 3)
        XCTAssertLessThan(OLSignalingResume.window, 20) // server grace and tgcalls timeout are 20 s
    }
}
