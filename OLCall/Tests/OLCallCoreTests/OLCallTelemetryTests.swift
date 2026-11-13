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
        let m = s.summary
        XCTAssertEqual(m["inN"] as? Int, 11)
        XCTAssertEqual(m["inMin"] as? Int, 9)
        XCTAssertEqual(m["inP50"] as? Int, 25)
        XCTAssertEqual(m["outP50"] as? Int, 30)
        XCTAssertEqual(m["inBelow20MaxRunSec"] as? Int, 1)
        XCTAssertEqual(OLFpsSeries.csv([12, 15, 25]), "12,15,25")
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

    /// Every value must survive the live server's cleanExtra (string/number/bool, <= 24 keys, no secret-ish keys).
    func testLiveSafeMatchesServerRules() {
        let x: [String: Any] = ["in": [12, 15], "lastNSError": ["domain": "NSOSStatusErrorDomain", "code": 561017449],
                                "resumeKey": "nope", "ok": true, "gapMs": 251, "avg": 19.4, "route": "Speaker"]
        let y = OLLogExtra.liveSafe(x)
        XCTAssertEqual(y["in"] as? String, "12,15")
        XCTAssertEqual(y["lastNSErrorDomain"] as? String, "NSOSStatusErrorDomain")
        XCTAssertEqual(y["lastNSErrorCode"] as? Int, 561017449)
        XCTAssertNil(y["resumeKey"])
        XCTAssertEqual(y["x_resumek"] as? String, "nope")
        for (k, v) in y {
            XCTAssertFalse(OLLogExtra.isSecretish(k), k)
            XCTAssertTrue(v is String || v is Int || v is Double || v is Bool, k)
        }
        var many: [String: Any] = [:]
        for i in 0..<40 { many["k\(i)"] = i }
        XCTAssertLessThanOrEqual(OLLogExtra.liveSafe(many).count, 24)
    }
}
