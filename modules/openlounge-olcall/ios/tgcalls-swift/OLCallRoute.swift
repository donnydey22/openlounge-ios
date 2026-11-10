// OLCallRoute — which engine an Open Lounge call uses on iOS. Pure (no UIKit, no
// tgcalls) so it is unit-tested on the simulator, and the same rule as Android's
// OlcallRoute.eligible (minus the ABI/SDK checks: this wrapper is arm64 + iOS 15+
// only, and the app's floor is 16.4).
//
// The olcall/tgcalls engine (wss://<host>/v1/call on the Pion server) is chosen
// ONLY when the OL backend hands out CallMedia { provider: "olcall", url: ws(s)://...,
// token } (call:start / call:accept / call:get replies, "media" key). Item 4 makes the
// Railway backend send exactly that. CallMedia.iceServers rides along as the relay
// list fallback; the joined frame's iceServers win (OLRtcServers.select).
import Foundation

public enum OLCallRoute {
    public struct Olcall {
        public let url: URL
        public let token: String
        /// CallMedia.iceServers (TurnIceServer[] JSON) or nil; never logged.
        public let appIceServers: Any?
    }

    public static let provider = "olcall"

    /// `media` = the backend's CallMedia dictionary (or nil / NSNull).
    public static func olcall(from media: Any?) -> Olcall? {
        guard let m = media as? [String: Any],
              m["provider"] as? String == provider,
              let s = m["url"] as? String, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              url.host?.isEmpty == false,
              let token = m["token"] as? String, !token.isEmpty else { return nil }
        let ice = (m["iceServers"] as? [Any]).flatMap { $0.isEmpty ? nil : $0 }
        return Olcall(url: url, token: token, appIceServers: ice)
    }
}
