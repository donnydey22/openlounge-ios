// First Open Lounge call UI (web 101e00a, 2026-10-07 10:51 PM MST): full-screen #0b1220
// stage, drifting blobs + blurred photo, pulsing rings while calling, 56pt RoundBtn with
// a 12pt label (Speaker, Flip when the camera is on, Video, Mute, End call), draggable
// 100×150 PiP with 18pt corners (dragged, snapped to a corner by Telegram's rule, CallPip), controls over the
// video on Telegram's top/bottom shadows, 4s control autohide on video, green minimize bar, end card.
// Wired only to the existing Pion-engine CallController
import SwiftUI

struct CallScreen: View {
    @ObservedObject var call: CallController
    @State private var swap = false
    @State private var showCtl = true
    @State private var hideTask: Task<Void, Never>?

    /// Video only once media flows after the answer (call.live); before it the opaque pre-answer card covers any preview.
    var videoStage: Bool { !call.failed && !call.endedCard && call.live && (call.remoteVideoOn || call.cameraOn) }
    /// Calling / Ringing / Connecting: avatar, name, status and one Cancel (same as Android).
    var preAnswer: Bool { !call.failed && !call.endedCard && !call.live }
    /// Failure or end card: no bottom row (its space stays reserved), Close top-right.
    var cardOnly: Bool { call.failed || call.endedCard }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                OLColor.stage.ignoresSafeArea()
                if videoStage {
                    videoLayer
                } else {
                    CallBackdrop(name: call.peerName, photoURL: call.peerPhoto)
                }
                if videoStage && showCtl {
                    // Telegram DrKLO 3de37c8 VoIPFragment.java:917-923: 160pt shadows under the controls.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [Color.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
                        Spacer()
                        LinearGradient(colors: [.clear, Color.black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 160)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
                if videoStage && call.remoteVideoOn && call.cameraOn {
                    Pip(view: swap ? (call.remoteVideoView) : call.localVideoView, mirrored: !swap && call.facingFront, size: geo.size,
                        insets: CallPip.insets(controlsShown: showCtl, rowReserve: OLMetric.rowBottom + OLMetric.rowHeight + geo.safeAreaInsets.bottom)) {
                        swap.toggle()
                    }
                }

                VStack(spacing: 0) {
                    topBar
                    centerBlock
                    Spacer(minLength: 0)
                    if cardOnly {
                        Color.clear.frame(height: OLMetric.rowBottom + OLMetric.rowHeight + geo.safeAreaInsets.bottom)
                    } else if showCtl || !videoStage {
                        controlRow
                            .padding(.bottom, OLMetric.rowBottom + geo.safeAreaInsets.bottom)
                    } else {
                        Color.clear.frame(height: OLMetric.rowBottom + geo.safeAreaInsets.bottom)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .opacity(showCtl || !videoStage ? 1 : 0)
                if call.failed {
                    // Banner under the X, over the stage (does not push the avatar down), same as Android.
                    VStack(spacing: 0) {
                        Text(call.failedText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.60))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 16)
                            .padding(.top, OLMetric.failBannerTop)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if videoStage { poke() } }
        }
        .onAppear { if videoStage { poke() } }
        .onChange(of: videoStage, perform: { on in
            if on { poke() } else { showCtl = true; hideTask?.cancel() }
        })
        .accessibilityIdentifier("call-screen")
    }

    @ViewBuilder
    private var videoLayer: some View {
        let bigLocal = call.cameraOn && (!call.remoteVideoOn || swap)
        if bigLocal, let local = call.localVideoView {
            VideoSurface(view: local)
                .scaleEffect(x: call.facingFront ? -1 : 1, y: 1)
                .ignoresSafeArea()
        } else if let remote = call.remoteVideoView {
            VideoSurface(view: remote).ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            if cardOnly {
                Spacer().frame(width: 40, height: 40)
                Spacer()
                Button(action: { if call.failed { call.dismissFailed() } else { call.dismissEndCard() } }) {
                    CallGlyph(name: "ol_call_close", size: 20)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Close")
            } else if call.phase != .ended && !preAnswer {
                Button(action: { call.setMinimized(true) }) {
                    CallGlyph(name: "ol_call_chevron_down", size: 24)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Minimize call")
                .opacity(showCtl || !videoStage ? 1 : 0)
                Spacer()
            } else {
                Spacer().frame(width: 40, height: 40)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: OLMetric.topBar)
    }

    private var centerBlock: some View {
        VStack(spacing: 12) {
            if !videoStage {
                ZStack {
                    if call.phase == .calling {
                        RingPulse()
                    }
                    Avatar(name: call.peerName, photoURL: call.peerPhoto, presence: call.peerPresence)
                }
                .padding(.bottom, OLMetric.avatarGap - 12)
            }
            // 101e00a: name, then status 4pt under it (mt-1), same on Android and incoming.
            VStack(spacing: OLMetric.statusGap) {
                Text(call.peerName)
                    .font(.system(size: videoStage ? OLMetric.nameSizeVideo : OLMetric.nameSize, weight: .semibold))
                    .tracking(videoStage ? OLMetric.nameTracking * OLMetric.nameSizeVideo / OLMetric.nameSize : OLMetric.nameTracking)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                Text(call.statusText)
                    .font(.system(size: OLMetric.statusSize).monospacedDigit())
                    .foregroundColor(OLColor.status)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .accessibilityIdentifier("call-status")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OLMetric.horizontalPadding)
        .padding(.top, videoStage ? 8 : 0)
        .frame(maxHeight: videoStage ? nil : .infinity, alignment: videoStage ? .top : .center)
    }

    @ViewBuilder
    private var controlRow: some View {
        if preAnswer {
            HStack(alignment: .top, spacing: 0) {
                RoundButton(label: "Cancel", glyph: "ol_call_end", fill: OLColor.end) { call.end() }
            }
            .padding(.horizontal, OLMetric.rowPad)
            .accessibilityIdentifier("call-controls")
        } else {
            fullRow
        }
    }

    private var fullRow: some View {
        HStack(alignment: .top, spacing: 0) {
            // Same lucide glyphs as Android (Assets.xcassets ol_call_* = res/drawable ol_call_*).
            // Audio in-call: Speaker / Mute / End call. Video / Flip only on the video stage.
            RoundButton(label: "Speaker",
                        glyph: call.speakerOn ? "ol_call_speaker" : "ol_call_speaker_off",
                        on: call.speakerOn) { call.toggleSpeaker() }
            if call.cameraOn {
                RoundButton(label: "Flip", glyph: "ol_call_flip") { call.flip() }
            }
            if call.cameraOn || call.remoteVideoOn || videoStage {
                RoundButton(label: call.cameraOn ? "Camera" : "Video",
                            glyph: call.cameraOn ? "ol_call_video" : "ol_call_video_off",
                            on: call.cameraOn, enabled: call.canToggleVideo || call.phase == .active) {
                    call.toggleVideo()
                }
            }
            RoundButton(label: call.muted ? "Unmute" : "Mute",
                        glyph: call.muted ? "ol_call_mic_off" : "ol_call_mic",
                        on: call.muted) { call.toggleMute() }
            RoundButton(label: "End call", glyph: "ol_call_end", fill: OLColor.end) { call.end() }
        }
        .padding(.horizontal, OLMetric.rowPad)
        .accessibilityIdentifier("call-controls")
    }

    private func poke() {
        showCtl = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { showCtl = false }
        }
    }
}

struct MiniBar: View {
    @ObservedObject var call: CallController
    var body: some View {
        VStack(spacing: 0) {
            Button(action: { call.setMinimized(false) }) {
                HStack(spacing: 8) {
                    Circle().fill(Color.white).frame(width: 8, height: 8)
                        .opacity(0.35)
                        .modifier(Blink())
                    Text(call.peerName).lineLimit(1)
                    Text(call.statusText).monospacedDigit()
                    Text("· Tap to return")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: OLMetric.barHeight)
                .padding(.top, 0)
                .background(OLColor.bar)
            }
            .accessibilityIdentifier("call-bar")
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
    }
}

private struct Blink: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content.opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct CallBackdrop: View {
    let name: String
    let photoURL: URL?
    @State private var photoLoaded = false
    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 0.7
            ZStack {
                OLColor.stage
                // Indigo/slate blobs only when there is no profile photo, so a present
                // picture becomes the dark blurred backdrop (same as the first-design shots).
                if !photoLoaded {
                    Circle().fill(OLColor.avatar.opacity(0.55))
                        .frame(width: side, height: side)
                        .blur(radius: 60)
                        .offset(x: -side * 0.35, y: -side * 0.3)
                        .modifier(Drift(dx: side * 0.25, dy: side * 0.2, duration: 14))
                    Circle().fill(OLColor.blobB.opacity(0.55))
                        .frame(width: side, height: side)
                        .blur(radius: 60)
                        .offset(x: side * 0.4, y: side * 0.35)
                        .modifier(Drift(dx: -side * 0.22, dy: -side * 0.17, duration: 17))
                }
                if let url = photoURL, url.scheme == "https" || url.scheme == "http" || url.scheme == "file" {
                    AsyncImage(url: url) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                                .scaleEffect(1.15)
                                .blur(radius: 36)
                                .saturation(1.3)
                                .brightness(-0.15)
                                .onAppear { photoLoaded = true }
                        }
                    }
                }
                LinearGradient(colors: [OLColor.shadeTop, OLColor.shadeMid, OLColor.shadeBottom],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct Drift: ViewModifier {
    let dx: CGFloat
    let dy: CGFloat
    let duration: Double
    @State private var on = false
    func body(content: Content) -> some View {
        content.offset(x: on ? dx : 0, y: on ? dy : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct RingPulse: View {
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Ring(delay: Double(i) * 0.8)
            }
        }
        .frame(width: OLMetric.avatarSize, height: OLMetric.avatarSize)
        .allowsHitTesting(false)
    }
}

private struct Ring: View {
    let delay: Double
    @State private var go = false
    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.35), lineWidth: 2)
            .scaleEffect(go ? 1.9 : 1)
            .opacity(go ? 0 : 0.8)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.timingCurve(0.2, 0.6, 0.35, 1, duration: 2.4).repeatForever(autoreverses: false)) { go = true }
                }
            }
    }
}

/// Self-view placement, the Telegram rules (same math as Android CallPip.kt):
///  - four corner slots, default bottom-right (Telegram-iOS 279f89e VideoContainerView.swift:237);
///  - slot frame = corner of the inset area (VideoContainerView.swift:610-619);
///  - insets 12 left/right, top 60 while controls show (0 hidden), bottom = control row + 12
///    (PrivateCallScreen.swift:1013-1017);
///  - on release the centre is projected along the fling velocity, pos - v / (1000 ln 0.99), and the PiP snaps to
///    the nearest inset corner (VideoContainerView.swift:428-464).
/// Size and radius stay the first-design 100×150 / 18 (Telegram-iOS also rounds 18, VideoContainerView.swift:771-776).
enum CallPip {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    static func insets(controlsShown: Bool, rowReserve: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(top: controlsShown ? 60 : 0, left: OLMetric.pipInset,
                     bottom: (controlsShown ? rowReserve : 0) + OLMetric.pipInset, right: OLMetric.pipInset)
    }
    static func origin(_ c: Corner, size: CGSize, pip: CGSize, insets i: UIEdgeInsets) -> CGPoint {
        switch c {
        case .topLeft: return CGPoint(x: i.left, y: i.top)
        case .topRight: return CGPoint(x: size.width - i.right - pip.width, y: i.top)
        case .bottomLeft: return CGPoint(x: i.left, y: size.height - i.bottom - pip.height)
        case .bottomRight: return CGPoint(x: size.width - i.right - pip.width, y: size.height - i.bottom - pip.height)
        }
    }
    static func snap(center: CGPoint, velocity v: CGPoint, size: CGSize, insets i: UIEdgeInsets) -> Corner {
        let k = 1000.0 * log(0.99)
        let e = CGPoint(x: center.x - v.x / k, y: center.y - v.y / k)
        return Corner.allCases.min { a, b in dist(e, a, size, i) < dist(e, b, size, i) }!
    }
    private static func dist(_ e: CGPoint, _ c: Corner, _ size: CGSize, _ i: UIEdgeInsets) -> CGFloat {
        let px = (c == .topLeft || c == .bottomLeft) ? i.left : size.width - i.right
        let py = (c == .topLeft || c == .topRight) ? i.top : size.height - i.bottom
        return hypot(e.x - px, e.y - py)
    }
}

struct Pip: View {
    let view: UIView?
    var mirrored: Bool
    let size: CGSize
    let insets: UIEdgeInsets
    let onSwap: () -> Void
    @State private var corner: CallPip.Corner = .bottomRight
    @State private var drag: CGSize = .zero
    @State private var moving = false
    @State private var last: (t: Date, p: CGSize)?
    @State private var velocity: CGPoint = .zero

    private var pipSize: CGSize { CGSize(width: OLMetric.pipWidth, height: OLMetric.pipHeight) }
    private var origin: CGPoint { CallPip.origin(corner, size: size, pip: pipSize, insets: insets) }

    var body: some View {
        Group {
            if let view {
                VideoSurface(view: view)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            } else {
                Color.black
            }
        }
        .frame(width: OLMetric.pipWidth, height: OLMetric.pipHeight)
        .clipShape(RoundedRectangle(cornerRadius: OLMetric.pipCorner, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .position(x: origin.x + OLMetric.pipWidth / 2 + drag.width, y: origin.y + OLMetric.pipHeight / 2 + drag.height)
        .gesture(
            DragGesture()
                .onChanged { v in
                    moving = true
                    let now = Date()
                    if let l = last {
                        let dt = now.timeIntervalSince(l.t)
                        if dt > 0 { velocity = CGPoint(x: (v.translation.width - l.p.width) / dt, y: (v.translation.height - l.p.height) / dt) }
                    }
                    last = (now, v.translation)
                    drag = v.translation
                }
                .onEnded { v in
                    if hypot(v.translation.width, v.translation.height) < 6 {
                        onSwap()
                    } else {
                        let c = CGPoint(x: origin.x + OLMetric.pipWidth / 2 + v.translation.width,
                                        y: origin.y + OLMetric.pipHeight / 2 + v.translation.height)
                        corner = CallPip.snap(center: c, velocity: velocity, size: size, insets: insets)
                    }
                    drag = .zero
                    moving = false
                    last = nil
                    velocity = .zero
                }
        )
        .animation(moving ? nil : .easeOut(duration: 0.15), value: corner)
        .accessibilityIdentifier("call-pip")
    }
}

/// One lucide glyph from Assets.xcassets (vector PDF, template), drawn at the Android dp size.
struct CallGlyph: View {
    let name: String
    var size: CGFloat = OLMetric.buttonIconSize
    var body: some View {
        Image(name).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct RoundButton: View {
    let label: String
    var glyph: String? = nil
    var on = false
    var enabled = true
    var fill: Color? = nil
    var size: CGFloat = OLMetric.buttonSize
    var labelSize: CGFloat = OLMetric.buttonLabelSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(fill ?? (on ? OLColor.buttonOn : OLColor.button))
                    // Always an icon; the label sits under the disc (never text-only discs).
                    CallGlyph(name: glyph ?? "ol_call_phone")
                        .foregroundColor(fill != nil ? .white : (on ? OLColor.buttonOnIcon : .white))
                }
                .frame(width: size, height: size)
                Text(label)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundColor(OLColor.label)
                    .lineLimit(1)
                    .frame(maxWidth: 76, minHeight: 14, maxHeight: 14)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : OLMetric.disabledOpacity)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }
}
