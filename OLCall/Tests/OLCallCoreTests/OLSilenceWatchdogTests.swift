@testable import OLCallCore
import XCTest

final class OLSilenceWatchdogTests: XCTestCase {
    func testRecoversThenReportsOnce() {
        let w = OLSilenceWatchdog(window: 6, floor: 0.0001, maxRecoveries: 2)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 0), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 5.9), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 6), .recover(attempt: 1))
        XCTAssertEqual(w.sample(level: 0, active: true, now: 12), .recover(attempt: 2))
        XCTAssertEqual(w.sample(level: 0, active: true, now: 18), .reportSilent)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 24), .none)
    }

    func testAudibleOrInactiveStartsOver() {
        let w = OLSilenceWatchdog(window: 6, maxRecoveries: 0)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 0), .none)
        XCTAssertEqual(w.sample(level: 0.2, active: true, now: 3), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 4), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 9), .none)
        XCTAssertEqual(w.sample(level: 0, active: false, now: 10), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 11), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 17), .reportSilent)
        w.reset()
        XCTAssertEqual(w.sample(level: 0, active: true, now: 18), .none)
        XCTAssertEqual(w.sample(level: 0, active: true, now: 24), .reportSilent)
    }
}
