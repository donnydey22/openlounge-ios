// Engine-side checks that need the linked TgVoipWebrtc.xcframework.
import XCTest
import OLCallCore
@testable import OLCall

final class OLCallEngineTests: XCTestCase {
    func testLinkedEngineSpeaksAServerVersion() {
        let local = OLTgcallsInstance.linkedVersions()
        XCTAssertNotNil(OLVersions.pick(local: local), "linked: \(local)")
    }

    func testConnectionsMapToEngineDescriptors() {
        let list = [
            OLRtcServers.Server(host: "t.example", port: 3478, login: "", password: "", isTurn: false, isTcp: false),
            OLRtcServers.Server(host: "t.example", port: 3478, login: "1:u", password: "p", isTurn: true, isTcp: false),
            OLRtcServers.Server(host: "t.example", port: 443, login: "1:u", password: "p", isTurn: true, isTcp: true),
        ]
        let c = OLTgcallsInstance.connections(list)
        XCTAssertEqual(c.count, 3)
        XCTAssertTrue(c[0].hasStun && !c[0].hasTurn && !c[0].hasTcp)
        XCTAssertTrue(!c[1].hasStun && c[1].hasTurn && !c[1].hasTcp && c[1].username == "1:u")
        XCTAssertTrue(c[2].hasTurn && c[2].hasTcp && c[2].port == 443)
        XCTAssertTrue(c.allSatisfy { $0.reflectorId == 0 })
    }

    func testCrumbURL() {
        XCTAssertEqual(OLBreadcrumbs.crumbURL(forCallURL: URL(string: "wss://turn.openlounge.app/v1/call?x=1")!).absoluteString,
                       "https://turn.openlounge.app/v1/crumbs")
    }
}
