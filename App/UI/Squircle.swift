// Squircle: Open Lounge's continuous-curve rounded shape (9c851a0: borderRadius 47 on 112 pt,
// borderCurve "continuous").
import SwiftUI

struct Squircle: Shape {
    var cornerRadius: CGFloat = OLMetric.avatarCorner

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
    }
}

extension View {
    /// Clip to the Open Lounge squircle. The default radius is the avatar's.
    func squircle(_ cornerRadius: CGFloat = OLMetric.avatarCorner) -> some View {
        clipShape(Squircle(cornerRadius: cornerRadius))
    }

    /// Avatar-proportioned squircle for any square size (47 / 112 of the side).
    func squircle(side: CGFloat) -> some View {
        squircle(side * OLMetric.avatarCorner / OLMetric.avatarSize)
    }
}
