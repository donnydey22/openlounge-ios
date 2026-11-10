// Golden frames shared with the Go server tests (olcall/integration/ios_frames_test.go):
// Fixtures/ios-frames.jsonl holds the frames for one real libtgcalls 13.0.0 call
// (blobs from tgproto/testdata/captured/linux-cli-default.jsonl). The Go side
// proves the server/sdpbridge accept and translate exactly these frames; this
// test proves OLSignalingRelay produces/consumes exactly these frames.
// STATUS: NOT RUN (needs macOS + Xcode; run via ios/OLTgcallsSwift/build.sh).
import XCTest
@testable import OLTgcalls

final class OLSignalingRelayTests: XCTestCase {
    private func fixture() throws -> [(dir: String, frame: [String: Any])] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ios-frames", withExtension: "jsonl", subdirectory: "Fixtures"))
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
                got = OLSignalingRelay.joinFrame(.init(token: "TOKEN", traceId: "0123456789abcdef", version: want["version"] as! String,
                                                       device: "iPhone15,2", os: "iOS 18.1"), seq: seq)
            case "blob":
                let blob = try XCTUnwrap(Data(base64Encoded: want["b64"] as! String))
                got = OLSignalingRelay.blobFrame(blob, seq: seq)
                blobs += 1
            case "hangup":
                got = OLSignalingRelay.hangupFrame(seq: seq)
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
            let text = String(data: try JSONSerialization.data(withJSONObject: f), encoding: .utf8)!
            switch OLSignalingRelay.decode(text) {
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

    func testDecodeRejectsGarbage() {
        if case .error = OLSignalingRelay.decode("not json") {} else { XCTFail() }
        if case .error = OLSignalingRelay.decode(#"{"t":"joined","key":"AAAA","isOutgoing":true}"#) {} else { XCTFail("short key accepted") }
    }

    func testVersionPick() {
        XCTAssertEqual(OLTgcallsVersion.pick(local: ["7.0.0", "11.0.0", "13.0.0", "14.0.0"]), "13.0.0")
        XCTAssertEqual(OLTgcallsVersion.pick(local: ["11.0.0", "14.0.0", "8.0.0"]), "8.0.0")
        XCTAssertNil(OLTgcallsVersion.pick(local: ["5.0.0", "11.0.0"]))
    }

    func testCrumbURL() {
        XCTAssertEqual(OLBreadcrumbs.crumbURL(forCallURL: URL(string: "wss://calls.example/v1/call?x=1")!).absoluteString,
                       "https://calls.example/v1/crumbs")
    }
}
