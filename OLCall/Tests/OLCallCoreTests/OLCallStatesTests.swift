// Port of Android OlCallStatesTest.kt: same transitions, same log lines, same diagnosis.
// Line format: olcall state <from> -> <to> reason=<r> t=<ms> call=<id>
import XCTest
@testable import OLCallCore

final class OLCallStatesTests: XCTestCase {
    private var clock: Int64 = 100
    private var out: [String] = []

    private func machine() -> OLCallStates {
        OLCallStates(nowMs: { [unowned self] in self.clock }, sink: { [unowned self] in self.out.append($0) })
    }

    override func setUp() { clock = 100; out = [] }

    func testHappyPathOutgoing() {
        let m = machine()
        XCTAssertEqual(m.state, .idle)
        m.setState(.joining, reason: "join-sent")
        clock += 120; m.callId = "c1"; m.setState(.offering, reason: "joined")
        m.blobSent(); m.blobReceived()
        clock += 1000; m.setState(.connected, reason: "tg-established")
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
        let m = machine()
        m.setState(.joining, reason: "join-sent"); m.callId = "c"; m.setState(.offering, reason: "joined")
        clock += 30_000; m.fail("connect-timeout")
        XCTAssertEqual(out.last, "olcall state offering -> failed reason=offer-never-sent:connect-timeout t=30000 call=c")
    }

    func testDiagnosisAnswerNeverArrived() {
        let m = machine()
        m.setState(.joining, reason: "join-sent"); m.setState(.offering, reason: "joined")
        m.blobSent(); m.blobSent()
        XCTAssertEqual(m.diagnose("tg-failed"), "answer-never-arrived:tg-failed")
    }

    func testDiagnosisIceStalled() {
        let m = machine()
        m.setState(.joining, reason: "join-sent"); m.setState(.answering, reason: "joined")
        m.blobReceived(); m.blobSent()
        XCTAssertEqual(m.diagnose("connect-timeout"), "ice-stalled:connect-timeout")
    }

    func testDiagnosisAnsweringSide() {
        let m = machine()
        m.setState(.joining, reason: "join-sent"); m.setState(.answering, reason: "joined")
        XCTAssertEqual(m.diagnose("x"), "offer-never-arrived:x")
        m.blobReceived()
        XCTAssertEqual(m.diagnose("x"), "answer-never-sent:x")
    }

    func testLineNeverCarriesSecrets() {
        // Reasons/ids are the only free text; the machine never sees tokens, keys, blobs or TURN creds.
        let l = OLCallStates.line(from: .idle, to: .joining, reason: "join-sent", ms: 5, callId: "")
        XCTAssertEqual(l, "olcall state idle -> joining reason=join-sent t=5 call=-")
        XCTAssertFalse(l.contains("token") || l.contains("credential") || l.contains("SECRET"))
    }

    // iOS additions: the socket close causes the engine reports, and the six state names.

    func testSocketCausesAreCarriedVerbatim() {
        let m = machine()
        m.setState(.joining, reason: "join-sent")
        m.fail("ws-closed:1006")
        XCTAssertEqual(out.last, "olcall state joining -> failed reason=join-never-acked:ws-closed:1006 t=0 call=-")
    }

    func testSixStates() {
        XCTAssertEqual([OLCallStates.State.idle, .joining, .offering, .answering, .connected, .failed].map(\.rawValue),
                       ["idle", "joining", "offering", "answering", "connected", "failed"])
    }

    func testAfterConnectDiagnosis() {
        let m = machine()
        m.setState(.joining, reason: "join-sent"); m.setState(.offering, reason: "joined"); m.setState(.connected, reason: "tg-established")
        XCTAssertEqual(m.diagnose("tg-failed"), "after-connect:tg-failed")
    }
}
