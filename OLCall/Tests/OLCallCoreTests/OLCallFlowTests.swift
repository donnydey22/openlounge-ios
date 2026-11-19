// BaoTime binding: same mapping, wording, tones and pulses as Android NativeCallFlowTest.
import XCTest
@testable import OLCallCore

final class OLCallFlowTests: XCTestCase {
    private func lc(_ s: String, _ r: String? = nil, seq: Int = 1) -> OLCallLifecycle {
        var o: [String: Any] = ["callId": "c1", "leg": "a", "state": s, "seq": seq, "event": "e"]
        if let r { o["reason"] = r }
        return OLCallLifecycle.parse(o)!
    }

    func testSevenStatesMapToScreens() {
        XCTAssertNil(OLCallFlow.screen(for: lc("idle")))
        XCTAssertEqual(OLCallFlow.screen(for: lc("ringing")), .ringing)
        XCTAssertEqual(OLCallFlow.screen(for: lc("answering")), .answering)
        XCTAssertEqual(OLCallFlow.screen(for: lc("joining_url")), .joining)
        XCTAssertEqual(OLCallFlow.screen(for: lc("connecting")), .connecting)
        XCTAssertEqual(OLCallFlow.screen(for: lc("in_room")), .active)
        XCTAssertEqual(OLCallFlow.screen(for: lc("terminal", "failed")), .failed)
        for r in ["declined", "missed", "disconnected", "expired", "cancelled_by_config", "completed"] {
            XCTAssertEqual(OLCallFlow.screen(for: lc("terminal", r)), .ended, r)
        }
    }

    func testWordingMatchesAndroid() {
        XCTAssertEqual(OLCallFlow.statusText(.ringing), "Ringing…")
        XCTAssertEqual(OLCallFlow.statusText(.answering), "Connecting…")
        XCTAssertEqual(OLCallFlow.statusText(.connecting), "Connecting…")
        XCTAssertEqual(OLCallFlow.statusText(.joining), "Joining…")
        XCTAssertEqual(OLCallFlow.statusText(.active), "")
        XCTAssertEqual(OLCallFlow.statusText(nil), "")
        XCTAssertEqual(OLCallFlow.endedText(.declined), "Declined")
        XCTAssertEqual(OLCallFlow.endedText(.missed), "No answer")
        XCTAssertEqual(OLCallFlow.endedText(.expired), "Link expired")
        XCTAssertEqual(OLCallFlow.endedText(.cancelledByConfig), "Call cancelled")
        XCTAssertEqual(OLCallFlow.endedText(.failed), "Call failed")
        XCTAssertEqual(OLCallFlow.endedText(.completed), "Call ended")
        XCTAssertEqual(OLCallFlow.endedText(.disconnected), "Call ended")
        XCTAssertEqual(OLCallFlow.timer(65), "1:05")
    }

    func testTonesAndPulses() {
        XCTAssertEqual(OLCallFlow.tone(.ringing).from, 0x4338CA)
        XCTAssertEqual(OLCallFlow.tone(.active).to, 0x059669)
        XCTAssertEqual(OLCallFlow.tone(.failed).to, 0xB91C1C)
        XCTAssertEqual(OLCallFlow.tone(.ended).from, 0x1E293B)
        XCTAssertEqual(OLCallFlow.pulseMs(.ringing), 2400)
        XCTAssertEqual(OLCallFlow.pulseMs(.joining), 1100)
        XCTAssertEqual(OLCallFlow.pulseMs(.connecting), 1100)
        XCTAssertEqual(OLCallFlow.pulseMs(.active), 0)
    }

    func testCallKitFollowsTheSameFrames() {
        XCTAssertEqual(OLCallFlow.callKit(for: lc("ringing")), .none)
        XCTAssertEqual(OLCallFlow.callKit(for: lc("connecting")), .startedConnecting)
        XCTAssertEqual(OLCallFlow.callKit(for: lc("in_room")), .connected)
        XCTAssertEqual(OLCallFlow.callKit(for: lc("terminal", "failed")), .ended(.failed))
        XCTAssertEqual(OLCallFlow.callKit(for: lc("terminal", "missed")), .ended(.unanswered))
        XCTAssertEqual(OLCallFlow.callKit(for: lc("terminal", "expired")), .ended(.unanswered))
        XCTAssertEqual(OLCallFlow.callKit(for: lc("terminal", "completed")), .ended(.remoteEnded))
    }

    func testEveryGoldenFrameMapsWithoutLocalState() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lifecycle", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for c in cases {
            for f in try XCTUnwrap(c["frames"] as? [[String: Any]]) {
                let l = try XCTUnwrap(OLCallLifecycle.parse(f))
                let s = OLCallFlow.screen(for: l)
                XCTAssertEqual(s == nil, l.state == .idle)
            }
        }
    }

    func testPushesSevenStatesToPage() {
        func l(_ s: OLCallLifecycle.State, _ r: OLCallLifecycle.Reason? = nil) -> OLCallLifecycle {
            OLCallLifecycle(callId: "c1", leg: "caller", state: s, reason: r, seq: 3, event: "e")
        }
        XCTAssertNil(OLCallFlow.pageDetail(callId: "c1", l(.idle)))
        XCTAssertEqual(OLCallFlow.pageState(for: l(.ringing)), .ringing)
        XCTAssertEqual(OLCallFlow.pageState(for: l(.answering)), .answering)
        XCTAssertEqual(OLCallFlow.pageState(for: l(.joiningUrl)), .joiningUrl)
        XCTAssertEqual(OLCallFlow.pageState(for: l(.connecting)), .connecting)
        XCTAssertEqual(OLCallFlow.pageState(for: l(.inRoom)), .active)
        XCTAssertEqual(OLCallFlow.pageState(for: l(.terminal, .failed)), .failed)
        for r in OLCallLifecycle.Reason.allCases where r != .failed {
            XCTAssertEqual(OLCallFlow.pageState(for: l(.terminal, r)), .terminal)
        }
        let d = OLCallFlow.pageDetail(callId: "c1", l(.terminal, .declined))!
        XCTAssertEqual(d["type"] as? String, "call:native-state")
        XCTAssertEqual(d["state"] as? String, "Terminal")
        XCTAssertEqual(d["reason"] as? String, "declined")
        XCTAssertEqual(d["seq"] as? Int64, 3)
        XCTAssertEqual(OLCallFlow.PageState.allCases.map(\.rawValue),
                       ["Ringing", "Answering", "JoiningUrl", "Connecting", "Active", "Failed", "Terminal"])
    }
}
