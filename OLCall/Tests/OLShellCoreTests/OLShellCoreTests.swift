import Foundation
@testable import OLShellCore
import XCTest

final class OLAppURLTests: XCTestCase {
    func testAppURLs() {
        XCTAssertTrue(OLAppURL.isAppURL("https://openlounge.app/rooms"))
        XCTAssertTrue(OLAppURL.isAppURL("https://WWW.openlounge.app"))
        XCTAssertTrue(OLAppURL.isAppURL("https://openlounge-production.up.railway.app/x"))
        XCTAssertFalse(OLAppURL.isAppURL("http://openlounge.app/"))
        XCTAssertFalse(OLAppURL.isAppURL("https://openlounge.app.evil.com/"))
        XCTAssertFalse(OLAppURL.isAppURL("https://evil.com@openlounge.app/"))
        XCTAssertFalse(OLAppURL.isAppURL("https://openlounge.app:8443/"))
        XCTAssertFalse(OLAppURL.isAppURL("javascript:alert(1)"))
    }

    func testOrigin() {
        XCTAssertEqual(OLAppURL.originOf("https://www.openlounge.app/a"), "https://www.openlounge.app")
        XCTAssertEqual(OLAppURL.originOf("https://evil.com/a"), "https://openlounge.app")
        XCTAssertEqual(OLAppURL.originOf(nil), "https://openlounge.app")
    }

    func testDeepLinks() {
        let t = OLAppURL.resolveIncomingLink("openlounge://room/abc?x=1", currentURL: "https://openlounge.app/")
        XCTAssertEqual(t, .init(url: "https://openlounge.app/room/abc?x=1", kind: .page, code: nil))
        XCTAssertEqual(OLAppURL.resolveIncomingLink("openlounge://../etc", currentURL: nil)?.url, "https://openlounge.app/")
        let a = OLAppURL.resolveIncomingLink("openlounge://auth?code=abc.DEF-1", currentURL: "https://www.openlounge.app/x")
        XCTAssertEqual(a, .init(url: "https://www.openlounge.app/auth/complete?code=abc.DEF-1", kind: .auth, code: "abc.DEF-1"))
        XCTAssertEqual(OLAppURL.resolveIncomingLink("openlounge://auth?error=access_denied", currentURL: nil)?.url,
                       "https://openlounge.app/auth/complete?error=access_denied")
        XCTAssertNil(OLAppURL.resolveIncomingLink("openlounge://auth?code=%3Cscript%3E", currentURL: nil))
        XCTAssertNil(OLAppURL.resolveIncomingLink("https://evil.com/", currentURL: nil))
        XCTAssertEqual(OLAppURL.resolveIncomingLink("https://openlounge.app/u/1", currentURL: nil)?.url, "https://openlounge.app/u/1")
    }

    func testNativeAuthStart() {
        XCTAssertTrue(OLAppURL.isNativeAuthStart("https://openlounge.app/auth/google/start?app=1"))
        XCTAssertTrue(OLAppURL.isNativeAuthStart("https://openlounge.app/auth/apple/start?app=1&x=2"))
        XCTAssertFalse(OLAppURL.isNativeAuthStart("https://openlounge.app/auth/google/start"))
        XCTAssertFalse(OLAppURL.isNativeAuthStart("https://evil.com/auth/google/start?app=1"))
    }

    func testCallAccept() {
        XCTAssertTrue(OLAppURL.isCallAcceptPath("/call/abc"))
        XCTAssertTrue(OLAppURL.isCallAcceptPath("/call/abc?accept=1"))
        XCTAssertTrue(OLAppURL.isCallAcceptPath("https://openlounge.app/call/abc?accept=1"))
        XCTAssertFalse(OLAppURL.isCallAcceptPath("/call/"))
        XCTAssertFalse(OLAppURL.isCallAcceptPath("/calls/abc"))
        XCTAssertEqual(OLAppURL.callAcceptURL(origin: "https://openlounge.app", callId: "c_1"), "https://openlounge.app/call/c_1?accept=1")
    }
}

final class OLBridgeMessageTests: XCTestCase {
    private func req(_ method: String, _ value: Any? = nil, id: String? = "r1") -> OLBridgeRequest? {
        var o: [String: Any] = ["__ol": 1, "method": method]
        if let value { o["value"] = value }
        if let id { o["id"] = id }
        let d = try! JSONSerialization.data(withJSONObject: o)
        return OLBridgeMessage.parse(String(data: d, encoding: .utf8)!)
    }

    func testRequests() {
        XCTAssertEqual(req("theme", "light"), .theme("light"))
        XCTAssertNil(req("theme", "blue"))
        XCTAssertEqual(req("haptic", "success"), .haptic(.success))
        XCTAssertNil(req("haptic", "boom"))
        XCTAssertEqual(req("setBadge", 3.7), .setBadge(3))
        XCTAssertNil(req("setBadge", -1))
        XCTAssertEqual(req("phoneAuthStart", ["id": "p", "phone": "+15551234567"]), .phoneAuthStart(id: "p", phone: "+15551234567"))
        XCTAssertNil(req("phoneAuthStart", ["id": "p", "phone": "5551234567"]))
        XCTAssertEqual(req("getSession"), .getSession(id: "r1"))
        XCTAssertNil(req("getSession", id: nil))
        XCTAssertEqual(req("setSession", "{}"), .setSession(id: "r1", value: "{}"))
        XCTAssertEqual(req("bioSetEnabled", true), .bioSetEnabled(id: "r1", on: true))
        XCTAssertNil(req("bioSetEnabled", 1))
        XCTAssertNil(req("nope"))
        XCTAssertNil(OLBridgeMessage.parse("not json"))
        XCTAssertNil(OLBridgeMessage.parse(#"{"method":"ready"}"#))
    }

    func testBoolsAreNotNumbers() {
        XCTAssertEqual(OLJSON(true), .bool(true))
        XCTAssertEqual(OLJSON(NSNumber(value: 1)), .number(1))
        let any = try! JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":0}"#.utf8))
        XCTAssertEqual(OLJSON(any).object?["a"], .bool(true))
        XCTAssertEqual(OLJSON(any).object?["b"], .number(1))
        XCTAssertEqual(OLJSON(any).object?["c"], .number(0))
    }

    func testNativeMedia() {
        guard case let .nativeMedia(id, cmd)? = req("nativeMedia", ["op": "connect", "callId": "c1", "video": true, "media": ["x": 1]]) else {
            return XCTFail("no nativeMedia")
        }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(OLMediaCommand.parse(cmd), .connect(callId: "c1", media: .object(["x": .number(1)]), video: true, caller: false))
        XCTAssertNil(req("nativeMedia", ["callId": "c1"]))
    }

    func testCallMessages() {
        XCTAssertEqual(OLBridgeMessage.parse(#"{"type":"call:outgoing","callId":"c1","name":"Ann","video":true}"#),
                       .call(.outgoing(callId: "c1", name: "Ann", video: true, photo: nil)))
        XCTAssertEqual(OLBridgeMessage.parse(#"{"type":"call:incoming","callId":"c1","name":"Ann","photo":"https://x/p.jpg","expiresAt":5}"#),
                       .call(.incoming(callId: "c1", name: "Ann", video: false, photo: "https://x/p.jpg", expiresAt: 5)))
        XCTAssertNil(OLBridgeMessage.parse(#"{"type":"call:outgoing","callId":"bad id!"}"#))
        XCTAssertEqual(OLBridgeMessage.parse(#"{"type":"call:ended"}"#), .call(.ended(callId: "")))
        XCTAssertNil(OLBridgeMessage.parse(#"{"type":"call:ended","callId":"../x"}"#))
        XCTAssertEqual(OLBridgeMessage.parse(#"{"type":"call:muted","muted":true}"#), .call(.muted(true)))
        XCTAssertEqual(OLBridgeMessage.parse(#"{"type":"call:audioRoute","speaker":false}"#), .call(.audioRoute(speaker: false)))
        XCTAssertNil(OLBridgeMessage.parse(#"{"type":"call:whatever"}"#))
    }
}

final class OLMediaCommandTests: XCTestCase {
    func testOps() {
        XCTAssertEqual(OLMediaCommand.parse(["op": .string("camera"), "on": .bool(true)]), .camera(on: true, front: true))
        XCTAssertEqual(OLMediaCommand.parse(["op": .string("camera"), "on": .bool(true), "facing": .string("environment")]), .camera(on: true, front: false))
        XCTAssertEqual(OLMediaCommand.parse(["op": .string("mute"), "muted": .bool(true)]), .mute(true))
        XCTAssertEqual(OLMediaCommand.parse(["op": .string("end")]), .close)
        XCTAssertEqual(OLMediaCommand.parse(["op": .string("close")]), .close)
        XCTAssertEqual(OLMediaCommand.parse(["op": .string("zzz")]), .unknown("zzz"))
        XCTAssertNil(OLMediaCommand.parse(["op": .string("connect"), "callId": .string("a b")]))
        XCTAssertNil(OLMediaCommand.parse([:]))
    }
}

final class OLBridgeScriptTests: XCTestCase {
    func testCapabilities() {
        let c = OLBridgeScript.capabilities(phoneAuth: false)
        for k in ["nativeMedia", "rtcP2P", "ol-rc-v1", "nativeVideo", "calls", "session"] { XCTAssertTrue(c.contains(k), k) }
        XCTAssertFalse(c.contains("phoneAuth"))
        XCTAssertTrue(OLBridgeScript.capabilities(phoneAuth: true).contains("phoneAuth"))
    }

    func testEscaping() {
        let s = OLBridgeScript.event("x", ["a": "</script>\u{2028}'\""])
        XCTAssertFalse(s.contains("\u{2028}"))
        XCTAssertTrue(s.contains("\\u2028"))
        XCTAssertTrue(OLBridgeScript.resolve(id: "a'b", ok: true, result: nil, error: nil).contains("\"a'b\",true,null,null"))
        XCTAssertTrue(OLBridgeScript.acceptCall("c1").contains("__olAcceptCall(\"c1\")"))
    }

    func testInjected() {
        let s = OLBridgeScript.injected(version: "0.4.0", build: "130", phoneAuth: true)
        XCTAssertTrue(s.contains("OpenLoungeNative"))
        XCTAssertTrue(s.contains("__olNativeCalls"))
        XCTAssertTrue(s.contains("messageHandlers.ol"))
        XCTAssertTrue(s.contains("\"rtcP2P\""))
    }
}

final class OLShellPolicyTests: XCTestCase {
    func testLock() {
        XCTAssertFalse(OLLockPolicy.shouldLock(enabled: false, backgroundedAt: 0, now: 100))
        XCTAssertTrue(OLLockPolicy.shouldLock(enabled: true, backgroundedAt: 0, now: 100))
        XCTAssertFalse(OLLockPolicy.shouldLock(enabled: true, backgroundedAt: 100, now: 150))
        XCTAssertTrue(OLLockPolicy.shouldLock(enabled: true, backgroundedAt: 100, now: 161))
        XCTAssertTrue(OLLockPolicy.shouldReportVisible(appActive: true, lock: .unlocked))
        XCTAssertFalse(OLLockPolicy.shouldReportVisible(appActive: true, lock: .locked))
        XCTAssertFalse(OLLockPolicy.shouldReportVisible(appActive: false, lock: .unlocked))
    }

    func testSession() {
        XCTAssertEqual(OLSessionAccess.from(#"{"access":"tok","accessExp":123}"#)?.token, "tok")
        XCTAssertNil(OLSessionAccess.from(#"{"access":""}"#))
        XCTAssertNil(OLSessionAccess.from(nil))
    }

    func testForegroundPush() {
        let d = OLForegroundPush.data(["type": "dm", "n": 1, "tag": "t"])
        XCTAssertEqual(d, ["type": "dm", "tag": "t"])
        XCTAssertFalse(OLForegroundPush.shouldForward(["type": "call_incoming"]))
        XCTAssertTrue(OLForegroundPush.shouldForward(["type": "dm"]))
        XCTAssertEqual(OLForegroundPush.openPath(["url": "/messages/u_1"]), "/messages/u_1")
        XCTAssertNil(OLForegroundPush.openPath(["url": "//evil.com"]))
        var q = OLForegroundPushQueue()
        q.enqueue(["tag": "a", "v": "1"]); q.enqueue(["v": "x"]); q.enqueue(["tag": "a", "v": "2"])
        XCTAssertEqual(q.drain(), [["v": "x"], ["tag": "a", "v": "2"]])
        XCTAssertEqual(q.drain(), [])
    }

    func testCallPhase() {
        XCTAssertEqual(OLCallPhase.from(.outgoing(callId: "c", name: "", video: false, photo: nil)), .calling)
        XCTAssertEqual(OLCallPhase.from(.answering(callId: "c", video: false)), .connecting)
        XCTAssertEqual(OLCallPhase.from(.connected(callId: "c")), .active)
        XCTAssertEqual(OLCallPhase.active.status(seconds: 75), "1:15")
        XCTAssertEqual(OLCallPhase.calling.status(seconds: 0), "Calling…")
    }
}

final class OLRingTests: XCTestCase {
    private let token = "v1.abcdefgh12." + String(repeating: "x", count: 30)

    func testParse() {
        let r = OLIncomingRing.parse(["type": "call_incoming", "callId": "c1", "callerId": "u1", "callerName": "Ann",
                                      "callerPhoto": "https://x/p.jpg", "video": "1", "expiresAt": "2000", "declineToken": token])
        XCTAssertEqual(r?.callId, "c1")
        XCTAssertEqual(r?.video, true)
        XCTAssertEqual(r?.expiresAt, 2000)
        XCTAssertEqual(r?.declineToken, token)
        XCTAssertEqual(r?.expired(nowMs: 1999), false)
        XCTAssertEqual(r?.expired(nowMs: 2000), true)
        let bad = OLIncomingRing.parse(["type": "call_incoming", "callId": "c1", "callerPhoto": "javascript:x", "declineToken": "nope"])
        XCTAssertNil(bad?.callerPhoto)
        XCTAssertNil(bad?.declineToken)
        XCTAssertEqual(bad?.expired(nowMs: 1e15), false)
        XCTAssertNil(OLIncomingRing.parse(["type": "dm", "callId": "c1"]))
        XCTAssertNil(OLIncomingRing.parse(["type": "call_incoming", "callId": "a/b"]))
    }

    func testUUID() {
        let a = OLCallIdentity.uuid(for: "c1")
        XCTAssertEqual(a, OLCallIdentity.uuid(for: "c1"))
        XCTAssertNotEqual(a, OLCallIdentity.uuid(for: "c2"))
        let s = a.uuidString
        XCTAssertEqual(Array(s)[14], "5")
        XCTAssertTrue("89AB".contains(Array(s)[19]))
    }

    func testSHA1() {
        let h = OLSHA1.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(h, "a9993e364706816aba3e25717850c26c9cd0d89d")
        let e = OLSHA1.hash([]).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(e, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testVoipToken() {
        XCTAssertEqual(OLCallIdentity.voipTokenHex(Data(repeating: 0xab, count: 32)), String(repeating: "ab", count: 32))
        XCTAssertNil(OLCallIdentity.voipTokenHex(Data([1, 2])))
    }
}
