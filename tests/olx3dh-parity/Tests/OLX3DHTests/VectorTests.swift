import XCTest
import Foundation
import Crypto
@testable import OLX3DH

final class VectorTests: XCTestCase {
  func hx(_ s: String) -> Data { var d = Data(); var i = s.startIndex; while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }; return d }
  func testWebVectorOpens() throws {
    let v = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.module.url(forResource: "olx3dh-vectors", withExtension: "json")!)) as! [String: Any]
    let pr = v["privHex"] as! [String: String], pu = v["pubHex"] as! [String: String], m = v["msg0"] as! [String: Any]
    for n in ["ika","eka","ikb","spkb","opkb"] { XCTAssertEqual(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hx(pr[n]!)).publicKey.rawRepresentation, hx(pu[n]!)) }
    let me = OLIdentity(dh: try .init(rawRepresentation: hx(pr["ikb"]!)), sig: .init())
    let s = try OLX3DHSession.respond(me, spk: try .init(rawRepresentation: hx(pr["spkb"]!)), opk: try .init(rawRepresentation: hx(pr["opkb"]!)),
      pre: ["ikDh": OLB64.enc(hx(pu["ika"]!)), "ek": OLB64.enc(hx(pu["eka"]!)), "spkId": 1, "opkId": 1])
    let env: [String: Any] = ["v": 1, "n": 0, "ct": m["ctB64u"]!]
    XCTAssertEqual(String(decoding: try s.open(env), as: UTF8.self), m["plaintext"] as! String)
    XCTAssertThrowsError(try s.open(env))
  }
  func testRoundTrip() throws {
    let a = OLIdentity(dh: .init(), sig: .init()), b = OLIdentity(dh: .init(), sig: .init())
    let spk = Curve25519.KeyAgreement.PrivateKey(), opk = Curve25519.KeyAgreement.PrivateKey()
    let bj: [String: Any] = ["deviceId": "devB", "ikDh": OLB64.enc(b.dh.publicKey.rawRepresentation), "ikSig": OLB64.enc(b.sig.publicKey.rawRepresentation), "spkId": 7,
      "spk": OLB64.enc(spk.publicKey.rawRepresentation), "spkSig": OLB64.enc(try b.sig.signature(for: spk.publicKey.rawRepresentation)), "opkId": 3, "opk": OLB64.enc(opk.publicKey.rawRepresentation)]
    let sa = try OLX3DHSession.initiate(a, OLBundle(bj)!)
    let e0 = try sa.seal(Data("offer".utf8)), e1 = try sa.seal(Data("ice".utf8))
    let sb = try OLX3DHSession.respond(b, spk: spk, opk: opk, pre: e0["pre"] as! [String: Any])
    XCTAssertEqual(try sb.open(e1), Data("ice".utf8)); XCTAssertEqual(try sb.open(e0), Data("offer".utf8))
    XCTAssertEqual(try sa.open(try sb.seal(Data("answer".utf8))), Data("answer".utf8))
    var bad = bj; bad["spk"] = bj["opk"]; XCTAssertThrowsError(try OLX3DHSession.initiate(a, OLBundle(bad)!))
  }
}
