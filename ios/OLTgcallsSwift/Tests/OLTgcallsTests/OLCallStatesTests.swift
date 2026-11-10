// State transitions + log line format (same as Android): olcall state <from> -> <to> reason=<r> t=<ms> call=<id>
import XCTest
@testable import OLTgcalls

final class OLCallStatesTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var out: [String] = []
    private func machine() -> OLCallStates { OLCallStates(now: { self.clock }, sink: { self.out.append($0) }) }

    func testHappyPathOutgoing() {
        let m = machine()
        XCTAssertEqual(m.state, .idle)
        m.setState(.joining, reason: "join-sent")
        clock += 0.120; m.callId = "c1"; m.setState(.offering, reason: "joined")
        m.blobSent(); m.blobReceived()
        clock += 1.000; m.setState(.connected, reason: "tg-established")
        XCTAssertEqual(out, [
            "olcall state idle -> joining reason=join-sent t=0 call=-",
            "olcall state joining -> offering reason=joined t=120 call=c1",
            "olcall state offering -> connected reason=tg-established t=1120 call=c1",
        ])
        XCTAssertEqual(m.lines, out)
    }

    func testIncomingIsAnswering() {
        let m = machine()
        m.setState(.joining, reason: "join-sent"); m.callId = "c2"
        m.setState(.answering, reason: "joined")
        XCTAssertEqual(out.last, "olcall state joining -> answering reason=joined t=0 call=c2")
    }

    func testSameStateIgnoredAndFailedIsTerminal() {
        let m = machine()
        m.setState(.joining, reason: "a")
        XCTAssertNil(m.setState(.joining, reason: "again"))
        m.fail("ws-failure")
        XCTAssertNil(m.setState(.connected, reason: "late"))
        XCTAssertNil(m.fail("again"))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last, "olcall state joining -> failed reason=join-never-acked:ws-failure t=0 call=-")
    }

    func testDiagnosisOfferNeverSent() {
        let m = machine(); m.setState(.joining, reason: "join-sent"); m.callId = "c"; m.setState(.offering, reason: "joined")
        clock += 30; m.fail("connect-timeout")
        XCTAssertEqual(out.last, "olcall state offering -> failed reason=offer-never-sent:connect-timeout t=30000 call=c")
    }

    func testDiagnosisAnswerNeverArrived() {
        let m = machine(); m.setState(.joining, reason: "join-sent"); m.setState(.offering, reason: "joined")
        m.blobSent(); m.blobSent()
        XCTAssertEqual(m.diagnose("tg-failed"), "answer-never-arrived:tg-failed")
    }

    func testDiagnosisIceStalled() {
        let m = machine(); m.setState(.joining, reason: "join-sent"); m.setState(.answering, reason: "joined")
        m.blobReceived(); m.blobSent()
        XCTAssertEqual(m.diagnose("connect-timeout"), "ice-stalled:connect-timeout")
    }

    func testDiagnosisAnsweringSide() {
        let m = machine(); m.setState(.joining, reason: "join-sent"); m.setState(.answering, reason: "joined")
        XCTAssertEqual(m.diagnose("x"), "offer-never-arrived:x")
        m.blobReceived()
        XCTAssertEqual(m.diagnose("x"), "answer-never-sent:x")
    }

    func testLineNeverCarriesSecrets() {
        // Reasons/ids are the only free text; the machine never sees tokens, keys, blobs or TURN creds.
        let l = OLCallStates.line(from: .idle, to: .joining, reason: "join-sent", ms: 5, callId: "")
        XCTAssertEqual(l, "olcall state idle -> joining reason=join-sent t=5 call=-")
    }
}
