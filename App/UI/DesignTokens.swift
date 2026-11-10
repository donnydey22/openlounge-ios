// Open Lounge call design tokens, salvaged from the first Open Lounge call UI in openlounge-ios:
//   call screen   d6135f0 (2026-11-04 17:43 MST) src/NativeCallScreen.tsx
//   avatar        9c851a0 (2026-11-04 19:55 MST) src/NativeCallScreen.tsx (squircle avatar, initials)
//   incoming card 325110e (2026-10-14 12:54 MST) src/IncomingCallCard.tsx
import SwiftUI

enum OLColor {
    // call screen (d6135f0)
    static let stage = Color(hex: 0x1C2B3A)
    static let button = Color.white.opacity(0.25)
    static let buttonOn = Color.white.opacity(0.6)
    static let end = Color(hex: 0xF4473A)
    static let status = Color.white.opacity(0.8)
    // avatar (9c851a0)
    static let avatar = Color(hex: 0x64748B)
    // incoming card (325110e)
    static let scrim = Color.black.opacity(0.45)
    static let card = Color(hex: 0x1C1C1E)
    static let cardBorder = Color.white.opacity(0.08)
    static let kicker = Color(hex: 0xA1A1AA)
    static let decline = Color(hex: 0x3F3F46)
    static let accept = Color(hex: 0x22C55E)
}

enum OLMetric {
    // call screen (d6135f0)
    static let topMargin: CGFloat = 96
    static let horizontalPadding: CGFloat = 24
    static let nameSize: CGFloat = 28
    static let statusSize: CGFloat = 16
    static let statusGap: CGFloat = 6
    static let buttonSize: CGFloat = 64
    static let buttonGap: CGFloat = 10          // marginHorizontal on each side
    static let buttonLabelSize: CGFloat = 11
    static let rowBottom: CGFloat = 56          // + safe-area bottom inset
    static let disabledOpacity: Double = 0.4
    // avatar squircle (9c851a0): 112 pt, corner 47 pt (~42 %), continuous curve
    static let avatarSize: CGFloat = 112
    static let avatarCorner: CGFloat = 47
    static let avatarGap: CGFloat = 12
    static let initialsSize: CGFloat = 30
    static let photoFade: Double = 0.2
    // incoming card (325110e)
    static let cardPadding: CGFloat = 22
    static let cardCorner: CGFloat = 24
    static let cardOuterPadding: CGFloat = 20
    static let cardBottom: CGFloat = 48
    static let kickerSize: CGFloat = 13
    static let kickerGap: CGFloat = 6
    static let cardNameSize: CGFloat = 26
    static let cardNameGap: CGFloat = 22
    static let cardButtonGap: CGFloat = 12
    static let cardButtonCorner: CGFloat = 22
    static let cardButtonVertical: CGFloat = 14
    static let cardButtonText: CGFloat = 16
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
