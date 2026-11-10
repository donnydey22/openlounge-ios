// OLRtcServers — relay list for the iPhone engine: standard RTCIceServer JSON ->
// tgcalls::RtcServer (Descriptor.rtcServers, reached through
// OngoingCallConnectionDescriptionWebrtc). ONE shared contract for both phones:
//  - the reference rules live in olcall/tgrtc (Go) and are pinned by the golden
//    fixture olcall/integration/testdata/rtcservers.json (copied byte-for-byte to
//    Tests/OLTgcallsTests/Fixtures/rtcservers.json); Android's OlRtcServers.kt and
//    this file must produce exactly that fixture's "expect" lists;
//  - the input has the same shape whether it comes from the olcall "joined" frame
//    (fresh coturn REST creds minted per leg at join time) or from the OL backend's
//    CallMedia.iceServers (src/lib/types.ts TurnIceServer).
//
// Rules (identical to OlRtcServers.kt): stun: -> STUN; turn: (udp default,
// ?transport=tcp) -> TURN with the short-lived username/credential; turns:/stuns:/
// unknown -> skipped (tgcalls' RtcServer has no TLS flag); username "reflector"
// (Telegram's own relay) -> skipped; default port 3478; hostnames kept (the device
// resolves them); duplicates dropped, order kept.
//
// Direct first / relay fallback: OLTgcallsCall keeps allowP2P = true, so host/srflx
// candidates are gathered and win on ICE priority; TURN relay candidates are used
// only when no direct pair works. Credentials are never logged (description and
// summary print hosts/counts only).
import Foundation
#if canImport(TgVoipWebrtc)
import TgVoipWebrtc
#endif

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

        /// Safe for logs/breadcrumbs: never includes the login or the credential.
        public var description: String {
            (isTurn ? (isTcp ? "turn-tcp" : "turn-udp") : "stun") + " \(host):\(port)"
        }
    }

    /// RTCIceServer[] JSON (as decoded by JSONSerialization) -> tgcalls servers.
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

    /// The server's joined.iceServers are minted per leg at join time, so they win.
    /// The backend's CallMedia.iceServers are used only when the joined frame has none.
    public static func select(joined: Any?, app: Any?) -> (servers: [Server], source: String) {
        let j = fromIceServers(joined)
        if !j.isEmpty { return (j, "joined") }
        let a = fromIceServers(app)
        return (a, a.isEmpty ? "none" : "app")
    }

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

    #if canImport(TgVoipWebrtc)
    /// tgcalls RtcServer entries via Telegram's ObjC descriptor
    /// (OngoingCallThreadLocalContext.mm: hasStun -> {isTurn:false}; hasTurn||hasTcp ->
    /// {id: reflectorId, isTurn:true, isTcp: hasTcp}). reflectorId 0 = not a Telegram
    /// reflector, the same RtcServer.id the Android JNI sets.
    public static func connections(_ list: [Server]) -> [OngoingCallConnectionDescriptionWebrtc] {
        list.map { s in
            OngoingCallConnectionDescriptionWebrtc(reflectorId: 0, hasStun: !s.isTurn, hasTurn: s.isTurn, hasTcp: s.isTurn && s.isTcp,
                                                   ip: s.host, port: Int32(s.port), username: s.login, password: s.password)
        }
    }
    #endif
}
