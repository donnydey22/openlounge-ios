// Incoming call card (325110e): dimmed stage, bottom card with kicker, caller name, and
// Decline / Accept side by side. The 9c851a0 squircle avatar leads the card.
import SwiftUI

struct IncomingCallScreen: View {
    @ObservedObject var call: CallController

    var body: some View {
        ZStack(alignment: .bottom) {
            OLColor.scrim.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Avatar(name: call.peerName, photoURL: call.peerPhoto, size: 56)
                    .padding(.bottom, OLMetric.avatarGap)
                Text(call.video ? "Open Lounge video call" : "Open Lounge audio call")
                    .font(.system(size: OLMetric.kickerSize, weight: .semibold))
                    .foregroundColor(OLColor.kicker)
                    .padding(.bottom, OLMetric.kickerGap)
                Text(call.peerName.isEmpty ? "Incoming call" : call.peerName)
                    .font(.system(size: OLMetric.cardNameSize, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .padding(.bottom, OLMetric.cardNameGap)
                HStack(spacing: OLMetric.cardButtonGap) {
                    CardButton(title: "Decline", fill: OLColor.decline) { call.decline() }
                    CardButton(title: "Accept", fill: OLColor.accept) { call.accept() }
                }
            }
            .padding(OLMetric.cardPadding)
            .background(OLColor.card)
            .clipShape(RoundedRectangle(cornerRadius: OLMetric.cardCorner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OLMetric.cardCorner, style: .continuous)
                .stroke(OLColor.cardBorder, lineWidth: 1 / UIScreen.main.scale))
            .padding(.horizontal, OLMetric.cardOuterPadding)
            .padding(.bottom, OLMetric.cardBottom)
        }
        .accessibilityIdentifier("incoming-call")
    }
}

private struct CardButton: View {
    let title: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: OLMetric.cardButtonText, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, OLMetric.cardButtonVertical)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: OLMetric.cardButtonCorner, style: .continuous))
        }
        .accessibilityLabel(title)
    }
}
