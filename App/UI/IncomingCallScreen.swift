// Incoming-call overlay only: a slim top pill over the unchanged Open Lounge canvas.
// Accept / Decline remain CallController's existing same-link CallKit / page routes.
import SwiftUI

struct IncomingCallScreen: View {
    @ObservedObject var call: CallController

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Avatar(name: call.peerName, photoURL: call.peerPhoto, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(call.peerName.isEmpty ? "Incoming call" : call.peerName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: call.video ? "video.fill" : "phone.fill")
                            .font(.system(size: 10))
                            .accessibilityHidden(true)
                        Text(call.video ? "Open Lounge video call" : "Open Lounge audio call")
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // FaceTime order: red X left, green checkmark right.
                bannerButton(glyph: "xmark", label: "Decline", color: OLColor.decline) { call.decline() }
                bannerButton(glyph: "checkmark", label: "Accept", color: OLColor.accept) { call.accept() }
            }
            .padding(12)
            .background(Color(hex: 0x1C1C1E).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Spacer()
        }
        .accessibilityIdentifier("incoming-call")
    }

    private func bannerButton(glyph: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(color)
                .clipShape(Circle())
        }
        .accessibilityLabel(label)
    }
}
