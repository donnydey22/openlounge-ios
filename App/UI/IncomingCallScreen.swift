// First Open Lounge incoming UI (web 101e00a, 2026-10-07 10:51 PM MST): full-screen
// stage with blurred avatar + presence dot, even 56pt Decline / Message / Accept (swipe
// up on the emerald Accept), "Open Lounge audio/video call", quick-reply sheet. Accept /
// Decline still go through CallController (existing Pion / CallKit path).
import SwiftUI

struct IncomingCallScreen: View {
    @ObservedObject var call: CallController
    @State private var replies = false
    @State private var dragY: CGFloat = 0

    private static let quick = [
        "Can't talk now. What's up?",
        "I'll call you right back.",
        "I'll call you later.",
        "Can't talk now. Call me later?",
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                OLColor.stage.ignoresSafeArea()
                CallBackdrop(name: call.peerName, photoURL: call.peerPhoto)
                VStack(spacing: 0) {
                    // Same frame as CallScreen: 56pt top bar, block centered above the 24 + 76 row.
                    Color.clear.frame(height: OLMetric.topBar)
                    Spacer()
                    ZStack {
                        RingPulse()
                        Avatar(name: call.peerName, photoURL: call.peerPhoto, presence: call.peerPresence)
                    }
                    .padding(.bottom, 12)
                    Text(call.peerName.isEmpty ? "Incoming call" : call.peerName)
                        .font(.system(size: OLMetric.nameSize, weight: .semibold))
                        .tracking(OLMetric.nameTracking)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text(call.video ? "Open Lounge video call" : "Open Lounge audio call")
                        .font(.system(size: OLMetric.statusSize))
                        .foregroundColor(OLColor.status)
                        .padding(.top, OLMetric.statusGap)
                    Spacer()
                    HStack(alignment: .bottom, spacing: 0) {
                        RoundButton(label: "Decline", glyph: "ol_call_end", fill: OLColor.decline, size: OLMetric.buttonSize, labelSize: OLMetric.buttonLabelSize) {
                            call.decline()
                        }
                        RoundButton(label: "Message", glyph: "ol_call_message", size: OLMetric.buttonSize, labelSize: OLMetric.buttonLabelSize) {
                            replies = true
                        }
                        acceptButton
                    }
                    .padding(.horizontal, OLMetric.rowPad)
                    .padding(.bottom, OLMetric.rowBottom + geo.safeAreaInsets.bottom)
                }
                .ignoresSafeArea(edges: .bottom)

                if replies { replySheet }
            }
        }
        .accessibilityIdentifier("incoming-call")
    }

    private var acceptButton: some View {
        // Hint is overlaid above the disc so the 56pt Accept circle stays on the same baseline as Decline / Message.
        ZStack(alignment: .top) {
            VStack(spacing: 6) {
                ZStack {
                    AcceptHalo()
                    Button(action: { call.accept() }) {
                        CallGlyph(name: call.video ? "ol_call_video" : "ol_call_phone")
                            .foregroundColor(.white)
                            .frame(width: OLMetric.buttonSize, height: OLMetric.buttonSize)
                            .background(OLColor.accept)
                            .clipShape(Circle())
                            .shadow(color: Color(hex: 0x064E3B).opacity(0.4), radius: 10, y: 6)
                            .modifier(AcceptPulse())
                    }
                    .accessibilityLabel(call.video ? "Accept video call" : "Accept")
                    .offset(y: dragY)
                    .gesture(
                        DragGesture()
                            .onChanged { v in dragY = min(0, v.translation.height) }
                            .onEnded { v in
                                if v.translation.height < -60 { call.accept() }
                                dragY = 0
                            }
                    )
                }
                Text("Accept")
                    .font(.system(size: OLMetric.buttonLabelSize, weight: .medium))
                    .foregroundColor(OLColor.label)
                    .frame(minHeight: 14, maxHeight: 14)
            }
            Text("swipe up")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
                .modifier(SwipeHint())
                .offset(y: -22)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
    }

    private var replySheet: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { replies = false }
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.2)).frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 8)
                ForEach(Self.quick, id: \.self) { t in
                    Button(action: { call.decline(); replies = false }) {
                        Text(t)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                }
                Button(action: { replies = false }) {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: 0x34D399))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.bottom, 12)
            .background(OLColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private struct AcceptPulse: ViewModifier {
    @State private var up = false
    func body(content: Content) -> some View {
        content.scaleEffect(up ? 1.08 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

private struct AcceptHalo: View {
    var body: some View {
        ZStack {
            Halo(delay: 0)
            Halo(delay: 0.7)
        }
        .allowsHitTesting(false)
    }
}

private struct Halo: View {
    let delay: Double
    @State private var go = false
    var body: some View {
        Circle()
            .fill(OLColor.halo)
            .frame(width: OLMetric.buttonBig, height: OLMetric.buttonBig)
            .scaleEffect(go ? 1.8 : 1)
            .opacity(go ? 0 : 0.7)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { go = true }
                }
            }
    }
}

private struct SwipeHint: ViewModifier {
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .offset(y: up ? -6 : 0)
            .opacity(up ? 1 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { up = true }
            }
    }
}
