// Keychain storage for the session and app preferences. Item layout (generic password, service
// "<service>:no-auth", account = generic = key bytes, after-first-unlock this device only) is the
// one Open Lounge 0.3.x used, so people who update stay signed in.
import Foundation
import Security

final class KeychainStore {
    static let session = KeychainStore(service: "com.donnydey.openlounge.session")
    static let prefs = KeychainStore(service: "com.donnydey.openlounge.prefs")

    private let service: String
    private let queue = DispatchQueue(label: "ol.keychain")
    init(service: String) { self.service = service }

    private func query(_ key: String, suffix: Bool) -> [String: Any] {
        let k = Data(key.utf8)
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: suffix ? "\(service):no-auth" : service,
                kSecAttrGeneric as String: k,
                kSecAttrAccount as String: k]
    }

    func get(_ key: String) -> String? {
        for suffix in [true, false] {
            var q = query(key, suffix: suffix)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
                return String(data: d, encoding: .utf8)
            }
        }
        return nil
    }

    @discardableResult
    func set(_ key: String, _ value: String) -> Bool {
        var q = query(key, suffix: true)
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status == errSecSuccess { SecItemDelete(query(key, suffix: false) as CFDictionary) }
        return status == errSecSuccess
    }

    func delete(_ key: String) {
        SecItemDelete(query(key, suffix: true) as CFDictionary)
        SecItemDelete(query(key, suffix: false) as CFDictionary)
    }

    // MARK: session (chunked: "openlounge.session.n" + "openlounge.session.<i>", 1800 chars each)

    private static let prefix = "openlounge.session"
    private static let chunk = 1800
    private static let maxChunks = 64

    private func count() -> Int {
        let n = Int(get("\(Self.prefix).n") ?? "") ?? 0
        return n > 0 && n <= Self.maxChunks ? n : 0
    }

    func getSession(_ done: @escaping (String?) -> Void) {
        queue.async {
            let n = self.count()
            var out = ""
            for i in 0..<n {
                guard let part = self.get("\(Self.prefix).\(i)") else { return done(nil) } // torn write
                out += part
            }
            done(n == 0 ? nil : out)
        }
    }

    func setSession(_ value: String, _ done: @escaping (Bool) -> Void) {
        if value.isEmpty { return clearSession { done(true) } }
        queue.async {
            var parts: [String] = []
            var rest = Substring(value)
            while !rest.isEmpty { parts.append(String(rest.prefix(Self.chunk))); rest = rest.dropFirst(Self.chunk) }
            guard parts.count <= Self.maxChunks else { return done(false) }
            let old = self.count()
            var ok = true
            for (i, p) in parts.enumerated() { ok = self.set("\(Self.prefix).\(i)", p) && ok }
            ok = self.set("\(Self.prefix).n", String(parts.count)) && ok
            if old > parts.count { for i in parts.count..<old { self.delete("\(Self.prefix).\(i)") } }
            done(ok)
        }
    }

    func clearSession(_ done: @escaping () -> Void) {
        queue.async {
            let old = self.count()
            self.delete("\(Self.prefix).n")
            for i in 0..<max(old, 1) { self.delete("\(Self.prefix).\(i)") }
            done()
        }
    }
}
