// Who is on the native call screen. The page's own call screen (CallOverlay, data-testid="call-screen") renders the
// other person from the server's call info, which the server fills from their CURRENT profile when the call starts
// (CallService.info -> store.publicUser): display name in [data-testid="call-name"], profile photo in the avatar
// <img>, presence in [data-presence]. The native screen follows that same source while ringing and in the call, so
// the outgoing "Calling…" card shows whatever name and photo the person has set in the app, not the chat header's
// snapshot that call:outgoing carries (Nov 12: outgoing card showed initials, the in-call screen the real photo).
// Read-only: these rules only decide what the screen shows; they never touch the call or its media.
import Foundation

public enum OLCallScreenIdentity {
    // Read-only page scripts. The attribute values are in double quotes: the b132 scripts wrote them as \' inside a
    // Swift literal, which Swift turns into a bare ' and the page got
    // document.querySelector('[data-testid='call-screen'] img') — a JavaScript SyntaxError, so the photo and presence
    // peeks never returned anything on iOS and the screen kept the initials and no presence dot for the whole call
    // (Android's twin scripts use \" and work). OLCallScreenIdentityTests compiles and runs each one in JavaScriptCore.

    /// The page call screen's (or incoming card's) display name, "" when none is on screen.
    public static let peekNameJS =
        "(function(){try{var r=document.querySelector('[data-testid=\"call-screen\"]')||document.querySelector('[data-testid=\"incoming-call\"]');var n=r&&r.querySelector('[data-testid=\"call-name\"]');return n?(n.textContent||''):'';}catch(e){return '';}})()"

    /// The page call screen's (or incoming card's) profile photo src (absolute http(s)), "" when none.
    public static let peekPhotoJS =
        "(function(){try{var img=document.querySelector('[data-testid=\"call-screen\"] img')||document.querySelector('[data-testid=\"incoming-call\"] img');var s=img&&img.src||'';if(s.indexOf('http')===0)return s;return '';}catch(e){return '';}})()"

    /// The page call screen's presence (data-presence: online / away / offline), "" when the page shows none.
    public static let peekPresenceJS =
        "(function(){try{var el=document.querySelector('[data-testid=\"call-screen\"] [data-presence]')||document.querySelector('[data-testid=\"incoming-call\"] [data-presence]');if(!el)return '';return el.getAttribute('data-presence')||'offline';}catch(e){return '';}})()"

    /// Same bound as the call:* messages (OLBridgeMessage.parseCall name).
    public static let maxName = 80

    /// A peeked page name -> the name to show now, or nil to keep the current one (nothing on the page, or unchanged).
    public static func name(peeked raw: String?, current: String) -> String? {
        let words = (raw ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let n = String(words.joined(separator: " ").prefix(maxName))
        guard !n.isEmpty, n != current else { return nil }
        return n
    }

    /// A peeked page photo src -> the photo to show now, or nil to keep the current one. Only http(s); a new URL
    /// (the person changed their photo) replaces the old one.
    public static func photo(peeked raw: String?, current: URL?) -> URL? {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard t.hasPrefix("https://") || t.hasPrefix("http://"), let u = URL(string: t), u != current else { return nil }
        return u
    }
}
