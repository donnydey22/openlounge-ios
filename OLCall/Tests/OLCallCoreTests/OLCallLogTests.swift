// OLCallLog: same tag table as Android OlCallLogTest.kt and server tests/calls/callLog.test.ts;
// the state machine is queued with timestamps and tags, survives a restart, uploads strip the token.
import XCTest
@testable import OLCallCore

final class OLCallLogTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("calllog-\(UUID().uuidString)").appendingPathComponent("queue.jsonl")
    }
    private func meta(_ tok: String? = "tok.sig") -> OLCallLog.Meta {
        OLCallLog.Meta(callId: "c1", role: "callee", media: "audio", device: "iPhone15,2", os: "iOS 18.1", appVersion: "0.4.0 (130)", engine: "e", olcallToken: tok)
    }

    func testEveryDiagnosedReasonMapsToATag() {
        let cases: [(String, String)] = [
            ("offer-never-sent:ws-failure", "offer_never_sent"), ("offer-never-arrived:tg-failed", "offer_never_sent"),
            ("answer-never-arrived:ws-closed:1006", "answer_timeout"), ("answer-never-sent:tg-failed", "answer_timeout"),
            ("ice-stalled:tg-failed", "ice_failure"), ("ice-stalled:ws-failure", "connection_stalled"),
            ("join-never-acked:ws-failure", "connection_stalled"), ("after-connect:ws-closed:1001", "connection_stalled"),
            ("audio-session-activation-failed", "audio_session_handoff_failure"), ("adm:open-report:ok=0", "audio_session_handoff_failure"),
            ("turn-alloc-failed:401", "turn_relay_failure"), ("no_turn", "turn_relay_failure"), ("ice-Failed", "ice_failure"),
            ("join-timeout", "answer_timeout"), ("ws-closed-before-media", "connection_stalled"), ("something new", "connection_stalled"),
            ("permission-denied", "permission_denied"), ("olcall-unavailable", "engine_unavailable"),
            ("join-never-acked:server-error:unauthorized", "join_rejected"),
        ]
        for (raw, tag) in cases { XCTAssertEqual(OLCallLogTags.tag(raw), tag, raw) }
        for t in OLCallLogTags.failure { XCTAssertEqual(OLCallLogTags.tag(t), t) }
        XCTAssertEqual(OLCallLogTags.tag("ice-stalled:tg-failed", relayOnly: true), "turn_relay_failure")
    }

    func testStateMachineQueuedWithTimestampsTagsAndSurvivesRestart() {
        let url = tmpURL()
        var clock: Int64 = 1000
        let states = OLCallStates(nowMs: { clock }, sink: { _ in })
        let log = OLCallLog(queue: OLCallLogQueue(url: url), uploader: nil, meta: meta(), nowMs: { 9000 + clock })
        log.relayOnly = false
        log.attach(states)
        states.setState(.joining, reason: "join-sent"); clock = 1120
        states.setState(.answering, reason: "joined"); states.blobReceived(); clock = 1900
        states.fail("tg-failed")
        let ev = OLCallLogQueue(url: url).all() // a new queue object on the same file = app restart
        XCTAssertEqual(ev.map { $0["to"] as? String }, ["joining", "answering", "failed"])
        XCTAssertEqual(ev.map { $0["from"] as? String }, ["idle", "joining", "answering"])
        XCTAssertEqual(ev.map { ($0["t"] as? NSNumber)?.int64Value }, [0, 120, 900])
        XCTAssertEqual(ev[2]["reason"] as? String, "answer_timeout")
        XCTAssertEqual(ev[2]["detail"] as? String, "answer-never-sent:tg-failed")
        for e in ev {
            XCTAssertEqual(e["source"] as? String, "ios"); XCTAssertEqual(e["role"] as? String, "callee")
            XCTAssertEqual(e["device"] as? String, "iPhone15,2"); XCTAssertEqual(e["media"] as? String, "audio")
        }
    }

    func testAudioSessionFailureTagsTheFailure() {
        let q = OLCallLogQueue(url: tmpURL())
        let states = OLCallStates(nowMs: { 0 }, sink: { _ in })
        let log = OLCallLog(queue: q, uploader: nil, meta: meta()); log.attach(states)
        states.setState(.joining, reason: "join-sent")
        log.event("audio_session", reason: "audio_session_handoff_failure", detail: "NSOSStatusErrorDomain:561017449:1")
        states.fail("ws-failure")
        XCTAssertEqual(q.all().last?["reason"] as? String, "audio_session_handoff_failure")
    }

    func testUploaderStripsTokenRemovesOnSuccessKeepsOffline() {
        let q = OLCallLogQueue(url: tmpURL())
        let log = OLCallLog(queue: q, uploader: nil, meta: meta("tokA.sig"))
        log.failedBeforeStart("permission-denied"); log.event("ended", reason: "normal", detail: "local-hangup")
        var code = -1
        var bodies: [[String: Any]] = []
        let up = OLCallLogUploader(queue: q, endpoint: { OLCallLog.endpoint }, bearer: { nil }) { _, _, body, done in
            bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]); done(code)
        }
        var n = -1
        up.flush { n = $0 }; XCTAssertEqual(n, 0); XCTAssertEqual(q.count, 2)
        code = 200
        up.flush { n = $0 }; XCTAssertEqual(n, 2); XCTAssertEqual(q.count, 0)
        let last = bodies.last!
        XCTAssertEqual(last["olcallToken"] as? String, "tokA.sig")
        let evs = last["events"] as? [[String: Any]] ?? []
        XCTAssertTrue(evs.allSatisfy { $0["_tok"] == nil })
        XCTAssertEqual(evs.first?["reason"] as? String, "permission_denied")
    }

    func testQueueBoundedAndClaims() {
        let q = OLCallLogQueue(url: tmpURL(), maxEvents: 5)
        let log = OLCallLog(queue: q, uploader: nil, meta: meta())
        for i in 0..<12 { log.event("e\(i)") }
        XCTAssertEqual(q.count, 5); XCTAssertEqual(q.all().last?["event"] as? String, "e11")
        let p1 = Data(#"{"callId":"abc-1","userId":"u","role":"caller","exp":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(OLCallLog.claims("\(p1).sig")?.callId, "abc-1")
        XCTAssertEqual(OLCallLog.claims("\(p1).sig")?.role, "caller")
        XCTAssertNil(OLCallLog.claims("garbage"))
    }
}
