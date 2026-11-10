// Open Lounge call design tokens from the first calling UI/UX
// (web repo donnydey22/openlounge, commit 101e00a, 2026-10-07 10:51 PM MST):
// src/components/calls/CallOverlay.tsx + calls.module.css
// Stage #0b1220, RoundBtn 56pt white/15 (active = white, zinc-900 icon), End/Decline red-500,
// Accept emerald-500 72pt pulse, Message 48pt, squircle avatar 112 / corner 47.
import SwiftUI

enum OLColor {
    static let stage = Color(hex: 0x0B1220)
    static let button = Color.white.opacity(0.15)
    static let buttonOn = Color.white
    static let buttonOnIcon = Color(hex: 0x18181B)
    static let end = Color(hex: 0xEF4444)          // red-500
    static let accept = Color(hex: 0x10B981)       // emerald-500
    static let decline = Color(hex: 0xEF4444)
    static let status = Color.white.opacity(0.8)
    static let label = Color.white.opacity(0.85)
    static let avatar = Color(hex: 0x64748B)
    static let blobB = Color(hex: 0x6366F1)
    static let bar = Color(hex: 0x10B981)
    static let shadeTop = Color.black.opacity(0.25)
    static let shadeMid = Color.black.opacity(0.05)
    static let shadeBottom = Color.black.opacity(0.55)
    static let halo = Color(hex: 0x34D399).opacity(0.45)
    // kept for any leftover card references; incoming is no longer a card
    static let scrim = Color.black.opacity(0.4)
    static let card = Color(hex: 0x18181B).opacity(0.95)
    static let cardBorder = Color.white.opacity(0.08)
    static let kicker = Color.white.opacity(0.8)
}

enum OLMetric {
    static let topMargin: CGFloat = 56
    static let horizontalPadding: CGFloat = 24
    static let nameSize: CGFloat = 28
    static let nameSizeVideo: CGFloat = 20
    static let statusSize: CGFloat = 15
    static let statusGap: CGFloat = 4
    static let buttonSize: CGFloat = 56
    static let buttonBig: CGFloat = 72
    static let buttonMessage: CGFloat = 48
    static let buttonGap: CGFloat = 8
    static let buttonLabelSize: CGFloat = 12
    static let incomingLabelSize: CGFloat = 13
    static let rowBottom: CGFloat = 24
    static let disabledOpacity: Double = 0.4
    static let avatarSize: CGFloat = 112
    static let avatarCorner: CGFloat = 47
    static let avatarGap: CGFloat = 12
    static let initialsSize: CGFloat = 30
    static let photoFade: Double = 0.2
    static let pipWidth: CGFloat = 100
    static let pipHeight: CGFloat = 150
    static let pipCorner: CGFloat = 18
    static let pipTop: CGFloat = 64
    static let pipInset: CGFloat = 12
    static let pipBottomReserve: CGFloat = 150
    static let barHeight: CGFloat = 28
    static let cardPadding: CGFloat = 12
    static let cardCorner: CGFloat = 24
    static let cardOuterPadding: CGFloat = 0
    static let cardBottom: CGFloat = 0
    static let kickerSize: CGFloat = 15
    static let kickerGap: CGFloat = 4
    static let cardNameSize: CGFloat = 28
    static let cardNameGap: CGFloat = 4
    static let cardButtonGap: CGFloat = 8
    static let cardButtonCorner: CGFloat = 999
    static let cardButtonVertical: CGFloat = 0
    static let cardButtonText: CGFloat = 13
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
