// OL clean-room X3DH + symmetric-ratchet call session ("OLX3DH-v1") — libsignal session *model*, NOT libsignal (AGPL).
// Byte-identical to web src/lib/calls/ringrtc/olx3dh.ts and Android OlX3dh.kt (contract + vectors:
// aud-openlounge docs/calling/RINGRTC-SESSION-AND-SIGNAL-RELAY.md, tests/calls/olx3dh-vectors.json). CryptoKit only.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto (Linux parity tests only)
#endif
import Foundation

public enum OLX3DHError: Error { case badSignature, badEnvelope, replay, tooFarAhead, missingPrekey, unknownKey }

public enum OLB64 {
  public static func enc(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  public static func dec(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
  }
}

public struct OLIdentity {
  public let dh: Curve25519.KeyAgreement.PrivateKey
  public let sig: Curve25519.Signing.PrivateKey
}

public struct OLBundle {
  public let deviceId: String; public let ikDh: Data; public let ikSig: Data; public let spkId: Int; public let spk: Data; public let spkSig: Data
  public let opkId: Int?; public let opk: Data?
  public init?(_ j: [String: Any]) {
    guard let d = j["deviceId"] as? String, let a = (j["ikDh"] as? String).flatMap(OLB64.dec), let b = (j["ikSig"] as? String).flatMap(OLB64.dec),
          let sid = (j["spkId"] as? NSNumber)?.intValue, let s = (j["spk"] as? String).flatMap(OLB64.dec), let ss = (j["spkSig"] as? String).flatMap(OLB64.dec) else { return nil }
    deviceId = d; ikDh = a; ikSig = b; spkId = sid; spk = s; spkSig = ss
    opkId = (j["opkId"] as? NSNumber)?.intValue; opk = (j["opk"] as? String).flatMap(OLB64.dec)
  }
}

enum OLKdf {
  static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Data) throws -> Data {
    let s = try priv.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub))
    return s.withUnsafeBytes { Data($0) }
  }
  static func hkdf(_ ikm: Data, _ info: String, _ n: Int) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(count: 32), info: Data(info.utf8), outputByteCount: n).withUnsafeBytes { Data($0) }
  }
  static func hmac(_ k: Data, _ b: UInt8) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data([b]), using: SymmetricKey(data: k))) }
  static func header(_ n: Int) -> Data { var be = UInt32(n).bigEndian; return Data([1]) + Data(bytes: &be, count: 4) }
}

public final class OLX3DHSession {
  private var sendCk: Data, recvCk: Data
  private let ad: Data
  private var pre: [String: Any]?
  private var sendN = 0, recvN = 0
  private var skipped: [Int: Data] = [:]
  private var skippedOrder: [Int] = []

  init(send: Data, recv: Data, ad: Data, pre: [String: Any]?) { sendCk = send; recvCk = recv; self.ad = ad; self.pre = pre }

  public static func initiate(_ me: OLIdentity, _ b: OLBundle) throws -> OLX3DHSession {
    guard let ikSig = try? Curve25519.Signing.PublicKey(rawRepresentation: b.ikSig), ikSig.isValidSignature(b.spkSig, for: b.spk) else { throw OLX3DHError.badSignature }
    let ek = Curve25519.KeyAgreement.PrivateKey()
    var ikm = Data(repeating: 0xFF, count: 32)
    ikm += try OLKdf.dh(me.dh, b.spk); ikm += try OLKdf.dh(ek, b.ikDh); ikm += try OLKdf.dh(ek, b.spk)
    if let o = b.opk { ikm += try OLKdf.dh(ek, o) }
    let ch = OLKdf.hkdf(OLKdf.hkdf(ikm, "OLX3DH-v1", 32), "OLCallChain-v1", 64)
    var pre: [String: Any] = ["ikDh": OLB64.enc(me.dh.publicKey.rawRepresentation), "ikSig": OLB64.enc(me.sig.publicKey.rawRepresentation), "ek": OLB64.enc(ek.publicKey.rawRepresentation), "spkId": b.spkId]
    if b.opk != nil, let id = b.opkId { pre["opkId"] = id }
    return OLX3DHSession(send: ch.prefix(32), recv: ch.suffix(32), ad: me.dh.publicKey.rawRepresentation + b.ikDh, pre: pre)
  }

  public static func respond(_ me: OLIdentity, spk: Curve25519.KeyAgreement.PrivateKey, opk: Curve25519.KeyAgreement.PrivateKey?, pre: [String: Any]) throws -> OLX3DHSession {
    guard let ikA = (pre["ikDh"] as? String).flatMap(OLB64.dec), let ek = (pre["ek"] as? String).flatMap(OLB64.dec) else { throw OLX3DHError.missingPrekey }
    var ikm = Data(repeating: 0xFF, count: 32)
    ikm += try OLKdf.dh(spk, ikA); ikm += try OLKdf.dh(me.dh, ek); ikm += try OLKdf.dh(spk, ek)
    if let o = opk { ikm += try OLKdf.dh(o, ek) }
    let ch = OLKdf.hkdf(OLKdf.hkdf(ikm, "OLX3DH-v1", 32), "OLCallChain-v1", 64)
    return OLX3DHSession(send: Data(ch.suffix(32)), recv: Data(ch.prefix(32)), ad: ikA + me.dh.publicKey.rawRepresentation, pre: nil)
  }

  public func confirmed() { pre = nil }

  public func seal(_ plain: Data) throws -> [String: Any] {
    let n = sendN; sendN += 1
    let mk = OLKdf.hmac(sendCk, 1), nonce = OLKdf.hmac(sendCk, 3).prefix(12)
    sendCk = OLKdf.hmac(sendCk, 2)
    let box = try AES.GCM.seal(plain, using: SymmetricKey(data: mk), nonce: AES.GCM.Nonce(data: nonce), authenticating: ad + OLKdf.header(n))
    var e: [String: Any] = ["v": 1, "n": n, "ct": OLB64.enc(box.ciphertext + box.tag)]
    if let pre { e["pre"] = pre }
    return e
  }

  public func open(_ e: [String: Any]) throws -> Data {
    guard (e["v"] as? NSNumber)?.intValue == 1, let n = (e["n"] as? NSNumber)?.intValue, n >= 0, let ct = (e["ct"] as? String).flatMap(OLB64.dec), ct.count >= 16 else { throw OLX3DHError.badEnvelope }
    // Authenticate against value snapshots; forged envelopes must not burn receive/skipped keys.
    var nextN = recvN, nextCk = recvCk
    var nextSkipped = skipped, nextOrder = skippedOrder
    let ck: Data
    if n < nextN {
      guard let k = nextSkipped.removeValue(forKey: n) else { throw OLX3DHError.replay }
      nextOrder.removeAll { $0 == n }; ck = k
    } else {
      guard n - nextN <= 256 else { throw OLX3DHError.tooFarAhead }
      while nextN < n { nextSkipped[nextN] = nextCk; nextOrder.append(nextN); nextN += 1; nextCk = OLKdf.hmac(nextCk, 2) }
      ck = nextCk; nextCk = OLKdf.hmac(nextCk, 2); nextN += 1
      while nextOrder.count > 256 { nextSkipped.removeValue(forKey: nextOrder.removeFirst()) }
    }
    let mk = OLKdf.hmac(ck, 1), nonce = OLKdf.hmac(ck, 3).prefix(12)
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct.prefix(ct.count - 16), tag: ct.suffix(16))
    let plain = try AES.GCM.open(box, using: SymmetricKey(data: mk), authenticating: ad + OLKdf.header(n))
    recvN = nextN; recvCk = nextCk; skipped = nextSkipped; skippedOrder = nextOrder
    return plain
  }
}
