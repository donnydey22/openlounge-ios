// Relay list (gap item 3) + engine route, pinned to the Go reference (olcall/tgrtc)
// through the shared golden fixture Fixtures/rtcservers.json, a byte-for-byte copy of
// olcall/integration/testdata/rtcservers.json (also used by Android's OlRtcServersTest).
import XCTest
@testable import OLTgcalls

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

    func testMatchesGoGoldenFixture() throws {
        let cases = try fixture()
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for c in cases {
            XCTAssertEqual(OLRtcServers.fromIceServers(c["iceServers"]), try expect(c["expect"]), c["name"] as? String ?? "?")
        }
    }

    func testLiveShapeIsDirectFirstRelayFallback() throws {
        let live = try fixture()[0]["iceServers"]
        let got = OLRtcServers.fromIceServers(live)
        XCTAssertEqual(OLRtcServers.summary(got), "stun=1 turnUdp=1 turnTcp=1")
        // tgcalls has no TLS TURN: turns:5349 must never become a plain TURN entry
        XCTAssertFalse(got.contains { $0.port == 5349 })
        XCTAssertEqual(got.map { "\($0.isTurn)/\($0.isTcp)" }, ["false/false", "true/false", "true/true"])
    }

    func testJoinedFrameCarriesIceServersAndWinsOverApp() throws {
        let live = try fixture()[0]["iceServers"]!
        var joined: [String: Any] = ["t": "joined", "callId": "c", "leg": "caller", "isOutgoing": true,
                                     "key": Data(repeating: 7, count: 256).base64EncodedString(), "versions": ["13.0.0"]]
        joined["iceServers"] = live
        let text = String(data: try JSONSerialization.data(withJSONObject: joined), encoding: .utf8)!
        guard case let .joined(j) = OLSignalingRelay.decode(text) else { return XCTFail("joined not decoded") }
        let app: [Any] = [["urls": "stun:b.example:3478"]]
        let (list, source) = OLRtcServers.select(joined: j.iceServers, app: app)
        XCTAssertEqual(source, "joined")
        XCTAssertEqual(list.count, 3)
        // No iceServers in joined -> the backend's CallMedia.iceServers are the fallback.
        let bare = #"{"t":"joined","callId":"c","leg":"callee","isOutgoing":false,"key":"\#(Data(repeating: 1, count: 256).base64EncodedString())"}"#
        guard case let .joined(j2) = OLSignalingRelay.decode(bare) else { return XCTFail("bare joined not decoded") }
        XCTAssertNil(j2.iceServers)
        let (l2, s2) = OLRtcServers.select(joined: j2.iceServers, app: app)
        XCTAssertEqual(s2, "app"); XCTAssertEqual(l2.first?.host, "b.example")
        XCTAssertEqual(OLRtcServers.select(joined: nil, app: nil).source, "none")
    }

    func testDescriptionAndSummaryNeverLeakCredentials() {
        let s = OLRtcServers.Server(host: "h", port: 3478, login: "1:u", password: "SECRETCRED", isTurn: true, isTcp: false)
        XCTAssertFalse(s.description.contains("SECRETCRED") || s.description.contains("1:u"))
        XCTAssertFalse(OLRtcServers.summary([s]).contains("SECRETCRED"))
    }

    func testConnectionsMapToTgcallsDescriptors() {
        let list = [
            OLRtcServers.Server(host: "t.example", port: 3478, login: "", password: "", isTurn: false, isTcp: false),
            OLRtcServers.Server(host: "t.example", port: 3478, login: "1:u", password: "p", isTurn: true, isTcp: false),
            OLRtcServers.Server(host: "t.example", port: 443, login: "1:u", password: "p", isTurn: true, isTcp: true),
        ]
        let c = OLRtcServers.connections(list)
        XCTAssertEqual(c.count, 3)
        XCTAssertTrue(c[0].hasStun && !c[0].hasTurn && !c[0].hasTcp)
        XCTAssertTrue(!c[1].hasStun && c[1].hasTurn && !c[1].hasTcp && c[1].username == "1:u")
        XCTAssertTrue(c[2].hasTurn && c[2].hasTcp && c[2].port == 443)
        XCTAssertTrue(c.allSatisfy { $0.reflectorId == 0 })
    }

    // MARK: engine route (same rule as Android OlcallRoute.eligible)

    private func media(provider: String = "olcall", url: String = "wss://calls.example/v1/call", token: String = "t",
                       ice: [Any]? = [["urls": ["stun:turn.example:3478"]]]) -> [String: Any] {
        var m: [String: Any] = ["provider": provider, "url": url, "token": token]
        if let ice { m["iceServers"] = ice }
        return m
    }

    func testRouteOlcallOnlyWhenBackendSaysSo() {
        let r = OLCallRoute.olcall(from: media())
        XCTAssertEqual(r?.url.absoluteString, "wss://calls.example/v1/call")
        XCTAssertEqual(r?.token, "t")
        XCTAssertEqual((r?.appIceServers as? [Any])?.count, 1)
        XCTAssertNil(OLCallRoute.olcall(from: media(provider: "p2p")), "today's p2p media keeps the existing path")
        XCTAssertNil(OLCallRoute.olcall(from: media(url: "https://calls.example/v1/call")))
        XCTAssertNil(OLCallRoute.olcall(from: media(url: "wss:///v1/call")))
        XCTAssertNil(OLCallRoute.olcall(from: media(token: "")))
        XCTAssertNil(OLCallRoute.olcall(from: nil))
        XCTAssertNil(OLCallRoute.olcall(from: NSNull()))
        XCTAssertNil(OLCallRoute.olcall(from: media(ice: [])).flatMap { $0.appIceServers }, "empty list = no app fallback")
        XCTAssertNotNil(OLCallRoute.olcall(from: media(url: "ws://127.0.0.1:7880/v1/call")))
    }
}
