import XCTest
@testable import OLCallCore

final class OLMediaResetTests: XCTestCase {
    func testPathChangeIgnoresFirstReadingAndDropsToNone() {
        XCTAssertFalse(OLMediaReset.shouldResetOnPathChange(from: nil, to: "wifi", connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 0))
        XCTAssertFalse(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "none", connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 0))
        XCTAssertTrue(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "cellular", connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 0))
        XCTAssertTrue(OLMediaReset.shouldResetOnPathChange(from: "cellular", to: "wifi", connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 0))
        XCTAssertFalse(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "cellular", connected: false, inFlight: false, ended: false, count: 0, last: nil, now: 0))
        XCTAssertFalse(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "cellular", connected: true, inFlight: true, ended: false, count: 0, last: nil, now: 0))
    }

    func testCooldownAndMax() {
        // cooldown 3 s since 8ba7dc8 (iOS 138, dual-connected Wi-Fi/cellular flaps), same as Android OlMediaReset.COOLDOWN_MS;
        // server reset-limited floor is 1.5 s, so a client reset after the cooldown is never refused for rate.
        XCTAssertEqual(OLMediaReset.cooldown, 3)
        XCTAssertFalse(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "cellular", connected: true, inFlight: false, ended: false, count: 0, last: 10, now: 12.9))
        XCTAssertTrue(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "cellular", connected: true, inFlight: false, ended: false, count: 0, last: 10, now: 13))
        XCTAssertFalse(OLMediaReset.shouldResetOnPathChange(from: "wifi", to: "cellular", connected: true, inFlight: false, ended: false, count: OLMediaReset.maxPerCall, last: nil, now: 0))
    }

    func testSilenceAfterResume() {
        XCTAssertFalse(OLMediaReset.shouldResetOnSilence(resumedAt: 10, flowing: false, connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 12.9))
        XCTAssertTrue(OLMediaReset.shouldResetOnSilence(resumedAt: 10, flowing: false, connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 13))
        XCTAssertFalse(OLMediaReset.shouldResetOnSilence(resumedAt: 10, flowing: true, connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 20))
        XCTAssertFalse(OLMediaReset.shouldResetOnSilence(resumedAt: nil, flowing: false, connected: true, inFlight: false, ended: false, count: 0, last: nil, now: 20))
    }
}
