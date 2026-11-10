// OLCallMedia — what the Open Lounge backend (Railway) hands a call participant on call start,
// accept or get: CallMedia { provider: "olcall", url: wss://.../v1/call, token, callId, expiresAt }.
// The token is a 5-minute olcall join token minted per role (caller / callee). Same acceptance
// rule as Android: provider "olcall", a ws(s) URL with a host, a token.
// Anything else is not a call this app can join.
import Foundation

public struct OLCallMedia: Equatable {
    public static let provider = "olcall"

    public let url: URL
    public let token: String
    public let callId: String

    public init(url: URL, token: String, callId: String) {
        self.url = url; self.token = token; self.callId = callId
    }

    /// `media` = the backend's CallMedia dictionary (or nil / NSNull).
    public static func parse(_ media: Any?) -> OLCallMedia? {
        guard let m = media as? [String: Any],
              m["provider"] as? String == provider,
              let s = m["url"] as? String, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              url.host?.isEmpty == false,
              let token = m["token"] as? String, !token.isEmpty else { return nil }
        return OLCallMedia(url: url, token: token, callId: m["callId"] as? String ?? "")
    }
}

/// Call control on the Open Lounge backend: start, accept, decline, hang up. Each start/accept
/// reply carries the participant's CallMedia. The concrete transport is supplied by the app.
public protocol OLCallControl: AnyObject {
    func start(peerId: String, video: Bool, completion: @escaping (Result<OLCallMedia, OLCallControlError>) -> Void)
    func accept(callId: String, completion: @escaping (Result<OLCallMedia, OLCallControlError>) -> Void)
    func decline(callId: String)
    func hangup(callId: String)
}

public enum OLCallControlError: Error, Equatable {
    case unavailable
    case rejected(String)
    case badMedia
}
