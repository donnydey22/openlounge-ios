// URL rules of the Open Lounge app shell: which pages stay inside the app (and may use the
// native bridge), how deep links and sign-in callbacks map to pages, and which pages bypass
// App Lock so a call can be answered. Same rules as the Open Lounge Android app.
import Foundation

public struct OLParsedURL: Equatable {
    public let scheme: String
    public let host: String
    public let port: String
    public let path: String
    public let query: String
    public let hash: String
    public let hasUserInfo: Bool
}

public enum OLAppURL {
    public static let startURL = "https://openlounge.app"
    public static let startOrigin = "https://openlounge.app"
    public static let scheme = "openlounge"
    public static let authCallbackScheme = "openlounge"
    public static let authCompletePath = "/auth/complete"
    public static let hosts: Set<String> = ["openlounge.app", "www.openlounge.app", "openlounge-production.up.railway.app"]

    public static func parse(_ raw: String) -> OLParsedURL? {
        guard raw.count <= 8192 else { return nil }
        for u in raw.unicodeScalars where u.value <= 0x20 || u.value == 0x7f || u == "\\" { return nil }
        guard let re = try? NSRegularExpression(pattern: "^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*)([^?#]*)(?:\\?([^#]*))?(?:#(.*))?$"),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: raw).map { String(raw[$0]) } }
        let authority = g(2) ?? ""
        let hasUserInfo = authority.contains("@")
        let hostPort = hasUserInfo ? String(authority[authority.index(after: authority.lastIndex(of: "@")!)...]) : authority
        var host = hostPort
        var port = ""
        if let c = hostPort.firstIndex(of: ":") {
            host = String(hostPort[..<c])
            port = String(hostPort[hostPort.index(after: c)...])
            guard port.allSatisfy(\.isASCIIDigit) else { return nil }
        }
        host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return OLParsedURL(scheme: (g(1) ?? "").lowercased(), host: host, port: port, path: g(3) ?? "",
                           query: g(4) ?? "", hash: g(5) ?? "", hasUserInfo: hasUserInfo)
    }

    public static func schemeOf(_ raw: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "^([a-zA-Z][a-zA-Z0-9+.-]*):"),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let r = Range(m.range(at: 1), in: raw) else { return "" }
        return raw[r].lowercased()
    }

    public static func queryParam(_ query: String, _ name: String) -> String? {
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let s = String(part)
            let eq = s.firstIndex(of: "=")
            let k = eq.map { String(s[..<$0]) } ?? s
            guard let key = k.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, key == name else { continue }
            let v = eq.map { String(s[s.index(after: $0)...]) } ?? ""
            return v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }

    /// "/room/abc?x=1": no scheme, no "//" authority, no "." / ".." segments, printable ASCII only.
    public static func isSafeAppPath(_ p: String) -> Bool {
        guard p.count <= 2048, p.hasPrefix("/"), !p.hasPrefix("//") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@%/?")
        guard p.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let path = p.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? p
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    public static func isAppHost(_ host: String) -> Bool { hosts.contains(host.lowercased()) }

    /// https URL on one of the app's own hosts (default port, no user info).
    public static func isAppURL(_ raw: String) -> Bool {
        guard let u = parse(raw) else { return false }
        return u.scheme == "https" && !u.hasUserInfo && (u.port.isEmpty || u.port == "443") && isAppHost(u.host)
    }

    public static func originOf(_ raw: String?) -> String {
        if let raw, isAppURL(raw), let u = parse(raw) { return "https://\(u.host)" }
        return startOrigin
    }

    public struct LinkTarget: Equatable {
        public enum Kind: Equatable { case auth, page }
        public let url: String
        public let kind: Kind
        public let code: String?
    }

    private static let authPaths: Set<String> = ["/auth", "/auth/", "/auth/exchange", "/auth/complete"]

    private static func authCompleteURL(_ origin: String, _ query: String) -> String? {
        if let code = queryParam(query, "code") {
            return matches(code, "^[A-Za-z0-9._~-]{1,512}$") ? "\(origin)\(authCompletePath)?code=\(encode(code))" : nil
        }
        let e = queryParam(query, "error").flatMap { matches($0, "^[a-z_]{1,32}$") ? $0 : nil } ?? "failed"
        return "\(origin)\(authCompletePath)?error=\(encode(e))"
    }

    /// Deep link, universal link or sign-in callback -> the https page the app opens.
    /// `currentURL` (the page on screen) picks the origin, so the sign-in verifier kept in that
    /// origin's storage is found.
    public static func resolveIncomingLink(_ raw: String, currentURL: String?) -> LinkTarget? {
        guard let u = parse(raw) else { return nil }
        if u.scheme == scheme {
            let origin = originOf(currentURL)
            let path = (u.host.isEmpty ? "" : "/\(u.host)") + (u.path == "/" ? "" : u.path)
            if authPaths.contains(path.isEmpty ? "/" : path) {
                return authCompleteURL(origin, u.query).map { LinkTarget(url: $0, kind: .auth, code: queryParam(u.query, "code")) }
            }
            let target = (path.isEmpty ? "/" : path) + (u.query.isEmpty ? "" : "?\(u.query)")
            return LinkTarget(url: isSafeAppPath(target) ? "\(origin)\(target)" : "\(origin)/", kind: .page, code: nil)
        }
        if u.scheme == "https" && isAppURL(raw) {
            let origin = "https://\(u.host)"
            if u.path == "/auth/exchange" || u.path == authCompletePath {
                return authCompleteURL(origin, u.query).map { LinkTarget(url: $0, kind: .auth, code: queryParam(u.query, "code")) }
            }
            return LinkTarget(url: raw, kind: .page, code: nil)
        }
        return nil
    }

    /// Google / Apple sign-in start that must run in ASWebAuthenticationSession.
    public static func isNativeAuthStart(_ raw: String) -> Bool {
        guard let u = parse(raw), u.scheme == "https", !u.hasUserInfo, isAppHost(u.host) else { return false }
        return matches(u.path, "^/auth/(google|apple)/start$") && queryParam(u.query, "app") == "1"
    }

    /// /call/<id> or /call/<id>?accept=1: App Lock steps aside so the call can be answered.
    public static func isCallAcceptPath(_ pathOrURL: String?) -> Bool {
        guard var p = pathOrURL, !p.isEmpty else { return false }
        if p.contains("://"), let u = URL(string: p) {
            p = u.path + (u.query.map { "?\($0)" } ?? "")
        }
        guard p.hasPrefix("/call/") else { return false }
        if p.contains("accept=1") { return true }
        let base = p.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? p
        let rest = base.dropFirst("/call/".count)
        return !rest.isEmpty && !rest.contains("/")
    }

    public static func callAcceptURL(origin: String, callId: String) -> String {
        "\(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/call/\(encode(callId))?accept=1"
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func encode(_ s: String) -> String {
        var a = CharacterSet.alphanumerics
        a.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
