import XCTest
@testable import OLCallCore

final class OLCallMediaTests: XCTestCase {
    private func media(provider: String = "olcall", url: String = "wss://turn.openlounge.app/v1/call", token: String = "t") -> [String: Any] {
        ["provider": provider, "url": url, "token": token, "callId": "c1", "expiresAt": 1]
    }

    func testOlcallMediaParses() {
        let m = OLCallMedia.parse(media())
        XCTAssertEqual(m, OLCallMedia(url: URL(string: "wss://turn.openlounge.app/v1/call")!, token: "t", callId: "c1"))
    }

    func testEverythingElseIsRejected() {
        XCTAssertNil(OLCallMedia.parse(media(provider: "other")))
        XCTAssertNil(OLCallMedia.parse(media(url: "https://turn.openlounge.app/v1/call")))
        XCTAssertNil(OLCallMedia.parse(media(url: "wss:///v1/call")))
        XCTAssertNil(OLCallMedia.parse(media(token: "")))
        XCTAssertNil(OLCallMedia.parse(nil))
        XCTAssertNil(OLCallMedia.parse(NSNull()))
        XCTAssertNotNil(OLCallMedia.parse(media(url: "ws://127.0.0.1:7880/v1/call")))
    }
}
