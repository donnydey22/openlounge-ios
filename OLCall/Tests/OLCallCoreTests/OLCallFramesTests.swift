// Golden frames for one real tgcalls 13.0.0 call (Fixtures/call-frames.jsonl), the same frames the
// Go server tests accept and Android's engine sends.
import XCTest
@testable import OLCallCore

final class OLCallFramesTests: XCTestCase {
    private func fixture() throws -> [(dir: String, frame: [String: Any])] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "call-frames", withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line in
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard let dir = o["dir"] as? String, dir != "meta" else { return nil }
            return (dir, try XCTUnwrap(o["frame"] as? [String: Any]))
        }
    }

    func testClientFramesMatchGolden() throws {
        var blobs = 0
        for (dir, want) in try fixture() where dir == "c2s" {
            let seq = UInt64(try XCTUnwrap(want["seq"] as? Int))
            let got: [String: Any]
            switch want["t"] as? String {
            case "join":
                got = OLCallFrames.join(.init(token: "TOKEN", traceId: "0123456789abcdef", version: try XCTUnwrap(want["version"] as? String),
                                              device: "iPhone15,2", os: "iOS 18.1"), seq: seq)
            case "blob":
                got = OLCallFrames.blob(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(want["b64"] as? String))), seq: seq)
                blobs += 1
            case "hangup":
                got = OLCallFrames.hangup(seq: seq)
            default:
                XCTFail("unexpected c2s frame \(want)"); continue
            }
            XCTAssertEqual(got as NSDictionary, want as NSDictionary)
        }
        XCTAssertGreaterThan(blobs, 0)
    }

    func testServerFramesDecode() throws {
        var sawJoined = false, blobs = 0, sawBye = false
        for (dir, f) in try fixture() where dir == "s2c" {
            let text = try XCTUnwrap(OLCallFrames.encode(f))
            switch OLCallFrames.decode(text) {
            case let .joined(j):
                sawJoined = true
                XCTAssertEqual(j.key.count, 256)
                XCTAssertTrue(j.isOutgoing)
                XCTAssertTrue(j.serverVersions.contains("13.0.0"))
            case let .blob(b):
                XCTAssertEqual(b, Data(base64Encoded: f["b64"] as! String))
                blobs += 1
            case .bye:
                sawBye = true
            default:
                XCTFail("unexpected decode of \(text)")
            }
        }
        XCTAssertTrue(sawJoined && sawBye)
        XCTAssertGreaterThan(blobs, 0)
    }

    func testJoinTokenRidesInTheFrameOnly() {
        let f = OLCallFrames.join(.init(token: "T0K", traceId: "t", version: "13.0.0", device: "d", os: "o"), seq: 1)
        XCTAssertEqual(f["token"] as? String, "T0K")
        XCTAssertEqual(f["surface"] as? String, "tgcalls")
        XCTAssertEqual(f["platform"] as? String, "ios")
    }

    func testDecodeRejectsGarbage() {
        if case .error = OLCallFrames.decode("not json") {} else { XCTFail() }
        if case .error = OLCallFrames.decode(#"{"t":"joined","key":"AAAA","isOutgoing":true}"#) {} else { XCTFail("short key accepted") }
        if case .ignored("offer") = OLCallFrames.decode(#"{"t":"offer"}"#) {} else { XCTFail("unknown frame not ignored") }
    }

    func testVersionPick() {
        XCTAssertEqual(OLVersions.pick(local: ["7.0.0", "11.0.0", "13.0.0", "14.0.0"]), "13.0.0")
        XCTAssertEqual(OLVersions.pick(local: ["11.0.0", "14.0.0", "8.0.0"]), "8.0.0")
        XCTAssertNil(OLVersions.pick(local: ["5.0.0", "11.0.0"]))
    }

    // Handover (call 11c994c9): resume key in "joined", resume / resumed frames.
    func testJoinedResumeKeyOptional() {
        let key = Data(repeating: 7, count: 256).base64EncodedString()
        guard case let .joined(a) = OLCallFrames.decode(#"{"t":"joined","callId":"c","leg":"caller","key":"\#(key)","isOutgoing":true,"resume":"UmVz"}"#) else { return XCTFail("joined") }
        XCTAssertEqual(a.resume, "UmVz")
        guard case let .joined(b) = OLCallFrames.decode(#"{"t":"joined","callId":"c","leg":"caller","key":"\#(key)","isOutgoing":true}"#) else { return XCTFail("joined (old server)") }
        XCTAssertNil(b.resume)
    }

    func testResumeFrames() {
        let f = OLCallFrames.resume(callId: "c1", leg: "callee", key: "K", traceId: "tr", seq: 9)
        XCTAssertEqual(OLCallFrames.encode(f), #"{"callId":"c1","leg":"callee","resume":"K","seq":9,"t":"resume","traceId":"tr"}"#)
        if case .resumed = OLCallFrames.decode(#"{"t":"resumed","callId":"c1","leg":"callee"}"#) {} else { XCTFail("resumed") }
    }
}
