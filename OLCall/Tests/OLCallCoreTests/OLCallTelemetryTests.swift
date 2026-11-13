import XCTest
@testable import OLCallCore

final class OLCallTelemetryTests: XCTestCase {
    func testFpsBatchesAndSummary() {
        var s = OLFpsSeries()
        var batches = 0
        for v in [9, 25, 25, 26, 25, 25, 24, 25, 25, 25, 18] { if s.add(inFps: v, outFps: 30) != nil { batches += 1 } }
        XCTAssertEqual(batches, 2)
        let tail = s.flush()
        XCTAssertEqual(tail?.in, [18])
        XCTAssertNil(s.flush())
        let inS = s.summary["in"] as? [String: Any]
        XCTAssertEqual(inS?["n"] as? Int, 11)
        XCTAssertEqual(inS?["min"] as? Int, 9)
        XCTAssertEqual(inS?["p50"] as? Int, 25)
        XCTAssertEqual(s.summary["inBelow20MaxRunSec"] as? Int, 1)
    }

    func testLongestBelow() {
        XCTAssertEqual(OLFpsSeries.longestBelow([25, 19, 18, 17, 25, 10], threshold: 20), 3)
        XCTAssertEqual(OLFpsSeries.longestBelow([], threshold: 20), 0)
    }

    func testNetTypeAndFourCC() {
        XCTAssertEqual(OLNetType.name(satisfied: true, wifi: true, cellular: true, wired: false), "wifi")
        XCTAssertEqual(OLNetType.name(satisfied: true, wifi: false, cellular: true, wired: false), "cellular")
        XCTAssertEqual(OLNetType.name(satisfied: false, wifi: true, cellular: false, wired: false), "none")
        XCTAssertEqual(OLAudioStatus.fourCC(561017449), "!pri")
        XCTAssertNil(OLAudioStatus.fourCC(-1))
        let d = OLAudioStatus.describe(NSError(domain: "NSOSStatusErrorDomain", code: 561017449))
        XCTAssertEqual(d["osstatus"] as? String, "!pri")
        XCTAssertEqual(d["code"] as? Int, 561017449)
    }
}
