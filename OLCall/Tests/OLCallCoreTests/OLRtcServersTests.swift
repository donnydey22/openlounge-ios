// TURN list rules, pinned by the golden fixture shared with Android's OlRtcServersTest and the Go server.
import XCTest
@testable import OLCallCore

final class OLRtcServersTests: XCTestCase {
    private func fixture() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rtcservers", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }

    private func expect(_ json: Any?) throws -> [OLRtcServers.Server] {
        guard let arr = json as? [[String: Any]] else { return [] }
        return try arr.map {
            OLRtcServers.Server(host: try XCTUnwrap($0["host"] as? String), port: try XCTUnwrap($0["port"] as? Int),
                                login: try XCTUnwrap($0["login"] as? String), password: try XCTUnwrap($0["password"] as? String),
                                isTurn: try XCTUnwrap($0["isTurn"] as? Bool), isTcp: try XCTUnwrap($0["isTcp"] as? Bool))
        }
    }

    func testMatchesGoldenFixture() throws {
        let cases = try fixture()
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for c in cases {
            XCTAssertEqual(OLRtcServers.fromIceServers(c["iceServers"]), try expect(c["expect"]), c["name"] as? String ?? "?")
        }
    }

    func testLiveShapeHasTurnUdpAndTcp() throws {
        let got = OLRtcServers.fromIceServers(try fixture()[0]["iceServers"])
        XCTAssertEqual(OLRtcServers.summary(got), "stun=1 turnUdp=1 turnTcp=1")
        XCTAssertTrue(OLRtcServers.hasTurn(got))
        XCTAssertFalse(got.contains { $0.port == 5349 }, "turns: must never become a plain TURN entry")
    }

    func testTurnIsMandatory() {
        XCTAssertFalse(OLRtcServers.hasTurn([]))
        XCTAssertFalse(OLRtcServers.hasTurn(OLRtcServers.fromIceServers([["urls": ["stun:turn.example:3478"]]])))
        XCTAssertFalse(OLRtcServers.hasTurn(OLRtcServers.fromIceServers([["urls": ["turn:turn.example:3478"]]])), "TURN without login is dropped")
    }

    func testJoinedFrameIceServersAreTheList() throws {
        var joined: [String: Any] = ["t": "joined", "callId": "c", "leg": "caller", "isOutgoing": true,
                                     "key": Data(repeating: 7, count: 256).base64EncodedString(), "versions": ["13.0.0"]]
        joined["iceServers"] = try fixture()[0]["iceServers"]
        let text = try XCTUnwrap(OLCallFrames.encode(joined))
        guard case let .joined(j) = OLCallFrames.decode(text) else { return XCTFail("joined not decoded") }
        XCTAssertEqual(OLRtcServers.fromIceServers(j.iceServers).count, 3)
    }

    func testDescriptionAndSummaryNeverLeakCredentials() {
        let s = OLRtcServers.Server(host: "h", port: 3478, login: "1:u", password: "SECRETCRED", isTurn: true, isTcp: false)
        XCTAssertFalse(s.description.contains("SECRETCRED") || s.description.contains("1:u"))
        XCTAssertFalse(OLRtcServers.summary([s]).contains("SECRETCRED"))
    }
}
