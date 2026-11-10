// OLRtcServers — the TURN/STUN list for one call: RTCIceServer JSON from the olcall "joined"
// frame -> engine relay servers. Same rules as Android's OlRtcServers.kt, pinned by the shared
// golden fixture (Tests/OLCallCoreTests/Fixtures/rtcservers.json):
//   stun: -> STUN; turn: (udp by default, ?transport=tcp) -> TURN with the short-lived
//   username/credential; turns:/stuns:/unknown -> skipped (the engine has no TLS flag);
//   username "reflector" -> skipped; default port 3478; hostnames kept; duplicates dropped, order kept.
// The joined frame is the only source: the Pion server mints the coturn login per leg at join time.
// Credentials are never logged (description and summary print hosts/counts only).
import Foundation

public enum OLRtcServers {
    public struct Server: Hashable, CustomStringConvertible {
        public let host: String
        public let port: Int
        public let login: String
        public let password: String
        public let isTurn: Bool
        public let isTcp: Bool

        public init(host: String, port: Int, login: String, password: String, isTurn: Bool, isTcp: Bool) {
            self.host = host; self.port = port; self.login = login; self.password = password
            self.isTurn = isTurn; self.isTcp = isTcp
        }

        /// Safe for logs: never includes the login or the credential.
        public var description: String {
            (isTurn ? (isTcp ? "turn-tcp" : "turn-udp") : "stun") + " \(host):\(port)"
        }
    }

    /// RTCIceServer[] JSON (as decoded by JSONSerialization) -> relay servers.
    public static func fromIceServers(_ json: Any?) -> [Server] {
        guard let arr = json as? [Any] else { return [] }
        var out: [Server] = []
        var seen = Set<Server>()
        for item in arr {
            guard let s = item as? [String: Any] else { continue }
            let user = s["username"] as? String ?? ""
            let cred = s["credential"] as? String ?? ""
            let list: [String]
            switch s["urls"] {
            case let a as [Any]: list = a.compactMap { $0 as? String }
            case let one as String: list = [one]
            default: list = []
            }
            for u in list {
                guard let srv = parse(u.trimmingCharacters(in: .whitespacesAndNewlines), user: user, cred: cred),
                      seen.insert(srv).inserted else { continue }
                out.append(srv)
            }
        }
        return out
    }

    /// TURN is mandatory: a list without at least one TURN entry cannot carry the call.
    public static func hasTurn(_ list: [Server]) -> Bool { list.contains { $0.isTurn } }

    /// Counts only (no hosts or credentials), for breadcrumbs.
    public static func summary(_ list: [Server]) -> String {
        "stun=\(list.filter { !$0.isTurn }.count) turnUdp=\(list.filter { $0.isTurn && !$0.isTcp }.count) turnTcp=\(list.filter { $0.isTurn && $0.isTcp }.count)"
    }

    static func parse(_ raw: String, user: String, cred: String) -> Server? {
        guard let colon = raw.firstIndex(of: ":"), colon > raw.startIndex else { return nil }
        let scheme = raw[..<colon].lowercased()
        var rest = String(raw[raw.index(after: colon)...])
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        var host = rest
        var port = 3478
        if rest.hasPrefix("[") {
            guard let end = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<end])
            let p = rest[rest.index(after: end)...]
            if p.hasPrefix(":") {
                guard let v = Int(p.dropFirst()) else { return nil }
                port = v
            }
        } else if let c = rest.lastIndex(of: ":") {
            guard let v = Int(rest[rest.index(after: c)...]) else { return nil }
            port = v
            host = String(rest[..<c])
        }
        guard !host.isEmpty, port > 0, port <= 65535 else { return nil }
        switch scheme {
        case "stun":
            return Server(host: host, port: port, login: "", password: "", isTurn: false, isTcp: false)
        case "turn":
            guard !user.isEmpty, !cred.isEmpty, user != "reflector" else { return nil }
            let tcp = query.split(separator: "&").contains { $0.lowercased() == "transport=tcp" }
            return Server(host: host, port: port, login: user, password: cred, isTurn: true, isTcp: tcp)
        default:
            return nil
        }
    }
}
