// Pinned to the Go writer (olcall/server/states.go) through the shared golden fixture Fixtures/lifecycle.json,
// the same file Android's OlCallLifecycleTest reads.
import XCTest
@testable import OLCallCore

final class OLCallLifecycleTests: XCTestCase {
    func testSevenStatesMatchGoWireValues() {
        XCTAssertEqual(OLCallLifecycle.State.allCases.map(\.rawValue),
                       ["idle", "ringing", "answering", "joining_url", "connecting", "in_room", "terminal"])
    }

    func testDecodesEveryGoldenFrame() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lifecycle", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for c in cases {
            var held: OLCallLifecycle?
            for want in try XCTUnwrap(c["frames"] as? [[String: Any]]) {
                let text = try XCTUnwrap(OLCallFrames.encode(["t": "call:state", "lifecycle": want]))
                guard case let .callState(l) = OLCallFrames.decode(text) else { return XCTFail("not decoded: \(text)") }
                XCTAssertEqual(l.state.rawValue, want["state"] as? String)
                XCTAssertEqual(l.reason?.rawValue ?? "", want["reason"] as? String ?? "")
                XCTAssertEqual(l.seq, (want["seq"] as? NSNumber)?.int64Value)
                XCTAssertEqual(l.event, want["event"] as? String)
                XCTAssertTrue(OLCallLifecycle.newer(held, l))
                held = l
            }
        }
    }

    func testInvalidSnapshotIsAnErrorNotACrash() {
        for bad in [#"{"t":"call:state"}"#,
                    #"{"t":"call:state","lifecycle":{"state":"reconnecting","seq":1}}"#,
                    #"{"t":"call:state","lifecycle":{"state":"terminal","seq":2}}"#,
                    #"{"t":"call:state","lifecycle":{"state":"in_room","reason":"completed","seq":2}}"#,
                    #"{"t":"call:state","lifecycle":{"state":"in_room","seq":0}}"#] {
            if case .error("bad-call-state") = OLCallFrames.decode(bad) {} else { XCTFail(bad) }
        }
    }

    func testStaleOrDuplicateSnapshotIsIgnored() throws {
        let a = try XCTUnwrap(OLCallLifecycle.parse(["state": "in_room", "seq": 3, "event": "peer:connected"]))
        let old = try XCTUnwrap(OLCallLifecycle.parse(["state": "connecting", "seq": 2, "event": "joined"]))
        XCTAssertFalse(OLCallLifecycle.newer(a, old))
        XCTAssertFalse(OLCallLifecycle.newer(a, a))
    }
}
