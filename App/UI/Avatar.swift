// Avatar (9c851a0): initials stay underneath, the profile photo fades in once loaded, a broken or
// non-http(s) URL leaves the initials. Squircle, #64748B, 30 pt medium white initials.
import SwiftUI

enum Initials {
    /// One word: its first two characters; several: first letter of the first and last word; none: "?".
    static func of(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return "?" }
        if words.count == 1 { return String(first.prefix(2)).uppercased() }
        return (String(first.prefix(1)) + String(words[words.count - 1].prefix(1))).uppercased()
    }
}

struct Avatar: View {
    let name: String
    let photoURL: URL?
    var size: CGFloat = OLMetric.avatarSize

    @State private var loaded = false

    var body: some View {
        ZStack {
            OLColor.avatar
            if !loaded {
                Text(Initials.of(name))
                    .font(.system(size: OLMetric.initialsSize * size / OLMetric.avatarSize, weight: .medium))
                    .foregroundColor(.white)
            }
            if let url = photoURL, url.scheme == "https" || url.scheme == "http" {
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
        .accessibilityHidden(true)
    }
}
