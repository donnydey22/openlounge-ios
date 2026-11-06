// Device-local OLX3DH-v1 keys in the Keychain (ThisDeviceOnly, AfterFirstUnlock so a VoIP push can answer while locked).
// Publishes the public bundle via rc:keys:publish; one-time prekeys deleted on use. No libsignal.
import CryptoKit
import Foundation
import Security

public final class OLRcKeyStore {
  public static let shared = OLRcKeyStore()
  private let service = "app.openlounge.rc.keys.v1"
  private let q = DispatchQueue(label: "ol.rc.keys")

  private func get(_ k: String) -> Data? {
    var out: AnyObject?
    let s = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: k, kSecReturnData: true] as CFDictionary, &out)
    return s == errSecSuccess ? out as? Data : nil
  }
  private func put(_ k: String, _ v: Data) {
    let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: k]
    SecItemDelete(base as CFDictionary)
    var add = base; add[kSecValueData] = v; add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }
  private func del(_ k: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: k] as CFDictionary) }
  private func int(_ k: String, _ d: Int) -> Int { get(k).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? d }
  private func setInt(_ k: String, _ v: Int) { put(k, Data(String(v).utf8)) }

  public var deviceId: String {
    q.sync {
      if let d = get("dev") { return String(decoding: d, as: UTF8.self) }
      var b = [UInt8](repeating: 0, count: 16); _ = SecRandomCopyBytes(kSecRandomDefault, 16, &b)
      let id = OLB64.enc(Data(b)); put("dev", Data(id.utf8)); return id
    }
  }

  public func identity() throws -> OLIdentity {
    try q.sync {
      if let d = get("ik.dh"), let s = get("ik.sig") {
        return OLIdentity(dh: try .init(rawRepresentation: d), sig: try .init(rawRepresentation: s))
      }
      let i = OLIdentity(dh: .init(), sig: .init())
      put("ik.dh", i.dh.rawRepresentation); put("ik.sig", i.sig.rawRepresentation)
      return i
    }
  }

  public func publishable(batch: Int = 20) throws -> [String: Any] {
    let id = try identity(), dev = deviceId
    return try q.sync {
      let spkId = int("spkNext", 1), spk = Curve25519.KeyAgreement.PrivateKey()
      put("spk.\(spkId)", spk.rawRepresentation); setInt("spkNext", spkId + 1)
      var next = int("opkNext", 1), opks: [[String: Any]] = []
      for _ in 0..<batch { let k = Curve25519.KeyAgreement.PrivateKey(); put("opk.\(next)", k.rawRepresentation); opks.append(["id": next, "pub": OLB64.enc(k.publicKey.rawRepresentation)]); next += 1 }
      setInt("opkNext", next)
      let sig = try id.sig.signature(for: spk.publicKey.rawRepresentation)
      return ["deviceId": dev, "ikDh": OLB64.enc(id.dh.publicKey.rawRepresentation), "ikSig": OLB64.enc(id.sig.publicKey.rawRepresentation),
              "spkId": spkId, "spk": OLB64.enc(spk.publicKey.rawRepresentation), "spkSig": OLB64.enc(sig), "opks": opks]
    }
  }

  public func spk(_ id: Int) throws -> Curve25519.KeyAgreement.PrivateKey {
    guard let d = q.sync(execute: { get("spk.\(id)") }) else { throw OLX3DHError.unknownKey }
    return try .init(rawRepresentation: d)
  }
  public func takeOpk(_ id: Int?) throws -> Curve25519.KeyAgreement.PrivateKey? {
    guard let id else { return nil }
    guard let d = q.sync(execute: { () -> Data? in let v = get("opk.\(id)"); del("opk.\(id)"); return v }) else { throw OLX3DHError.unknownKey }
    return try .init(rawRepresentation: d)
  }
}
