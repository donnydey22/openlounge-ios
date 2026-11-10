// Avatar (9c851a0): initials stay underneath, the profile photo fades in once loaded, a broken or
// non-http(s) URL leaves the initials. Squircle, #64748B, 30 pt medium white initials.
import SwiftUI

enum Initials {
    /// One word: its first two characters; several: first letter of the first and last word; none: "?".
    static func of(_ name: String) -> String {
        // Same as Android NativeCallScreen.initials: emoji / symbol words are skipped ("Keiko 🦋" -> "KE").
        let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { w in w.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } ?? false }
        guard let first = words.first else {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "?" : String(t.prefix(1))
        }
        if words.count == 1 { return String(first.prefix(2)).uppercased() }
        return (String(first.prefix(1)) + String(words[words.count - 1].prefix(1))).uppercased()
    }
}

enum CallPresence {
    static func of(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s.removeFirst(); s.removeLast() }
        switch s.lowercased() {
        case "online", "true", "1": return "online"
        case "away": return "away"
        default: return nil
        }
    }

    /// "presence" or "online" on a call:* payload the page already posted, if any.
    static func field(fromJSON raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let p = obj["presence"] {
            return of(String(describing: p))
        }
        if let o = obj["online"] {
            if let b = o as? Bool { return b ? "online" : nil }
            return of(String(describing: o))
        }
        return nil
    }

    static func hasField(inJSON raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["presence"] != nil || obj["online"] != nil
    }

    static let failMsg = "Can't connect the call on this network. Try another Wi-Fi or mobile data."

    static let peekPhotoJS =
        "(function(){try{var img=document.querySelector('[data-testid=\'call-screen\'] img')||document.querySelector('[data-testid=\'incoming-call\'] img');var s=img&&img.src||'';if(s.indexOf('http')===0)return s;return '';}catch(e){return '';}})()"

    static func object(fromJSON raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isFailure(fromJSON raw: String?) -> Bool {
        guard let raw, let obj = object(fromJSON: raw) else { return false }
        if (obj["reason"] as? String)?.lowercased() == "failed" { return true }
        let t = endText(obj)
        return t.contains("Can't connect the call on this network") || t.contains("Try another Wi-Fi")
    }

    static func failureText(fromJSON raw: String?) -> String {
        guard let raw, let obj = object(fromJSON: raw) else { return failMsg }
        let t = endText(obj)
        return t.isEmpty ? failMsg : t
    }

    private static func endText(_ obj: [String: Any]) -> String {
        for k in ["endedText", "error", "message", "text"] {
            if let s = obj[k] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }
}

struct Avatar: View {
    let name: String
    let photoURL: URL?
    var size: CGFloat = OLMetric.avatarSize
    /// "online" / "away"; nil hides the dot (offline or unknown), as 101e00a Avatar does.
    var presence: String? = nil

    @State private var loaded = false

    var body: some View {
        ZStack {
            OLColor.avatar
            if !loaded {
                Text(Initials.of(name))
                    .font(.system(size: OLMetric.initialsSize * size / OLMetric.avatarSize, weight: .medium))
                    .foregroundColor(.white)
            }
            if let url = photoURL, url.scheme == "https" || url.scheme == "http" || url.scheme == "file" {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: OLMetric.photoFade))) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                            .onAppear { loaded = true }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .squircle(side: size)
        .overlay(alignment: .bottomTrailing) {
            if let p = CallPresence.of(presence) {
                ZStack {
                    Circle().fill(OLColor.stage)
                        .frame(width: OLMetric.presenceDot + OLMetric.presenceRing * 2,
                               height: OLMetric.presenceDot + OLMetric.presenceRing * 2)
                    Circle().fill(p == "away" ? OLColor.presenceAway : OLColor.presenceOnline)
                        .frame(width: OLMetric.presenceDot, height: OLMetric.presenceDot)
                }
                .padding(.trailing, OLMetric.presenceInset)
                .padding(.bottom, OLMetric.presenceInset)
                .accessibilityLabel(p)
            }
        }
        .accessibilityHidden(presence == nil)
    }
}
