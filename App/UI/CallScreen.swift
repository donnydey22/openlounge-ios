// First Open Lounge call UI (web 101e00a, 2026-10-07 10:51 PM MST): full-screen #0b1220
// stage, drifting blobs + blurred photo, pulsing rings while calling, 56pt RoundBtn with
// a 12pt label (Speaker, Flip when the camera is on, Video, Mute, End call), draggable
// 100×150 PiP with 18pt corners, 4s control autohide on video, green minimize bar.
// Wired only to the existing Pion-engine CallController
import SwiftUI

struct CallScreen: View {
    @ObservedObject var call: CallController
    @State private var swap = false
    @State private var showCtl = true
    @State private var hideTask: Task<Void, Never>?

    var videoStage: Bool { !call.failed && (call.remoteVideoOn || call.cameraOn) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                OLColor.stage.ignoresSafeArea()
                if videoStage {
                    videoLayer
                } else {
                    CallBackdrop(name: call.peerName, photoURL: call.peerPhoto)
                }
                if videoStage && call.remoteVideoOn && call.cameraOn {
                    Pip(view: swap ? (call.remoteVideoView) : call.localVideoView, mirrored: !swap && call.facingFront, size: geo.size) {
                        swap.toggle()
                    }
                } else if videoStage && call.cameraOn, let local = call.localVideoView, !call.remoteVideoOn {
                    // outgoing video before the far side's tile is up: local is the big stage, already in videoLayer
                }

                VStack(spacing: 0) {
                    topBar
                    if call.failed {
                        Text(call.failedText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.60))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                    }
                    centerBlock
                    Spacer(minLength: 0)
                    if call.failed {
                        Color.clear.frame(height: 56 + geo.safeAreaInsets.bottom)
                    } else if showCtl || !videoStage {
                        controlRow
                            .padding(.bottom, OLMetric.rowBottom + geo.safeAreaInsets.bottom)
                    } else {
                        Color.clear.frame(height: OLMetric.rowBottom + geo.safeAreaInsets.bottom)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .opacity(showCtl || !videoStage ? 1 : 0)
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
            if call.failed {
                Spacer().frame(width: 40, height: 40)
                Spacer()
                Button(action: { call.dismissFailed() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Close")
            } else if call.phase != .ended {
                Button(action: { call.setMinimized(true) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
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
        .padding(.top, 8)
        .frame(height: 56)
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
            Text(call.peerName)
                .font(.system(size: videoStage ? OLMetric.nameSizeVideo : OLMetric.nameSize, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 4)
            Text(call.statusText)
                .font(.system(size: OLMetric.statusSize).monospacedDigit())
                .foregroundColor(OLColor.status)
                .shadow(color: .black.opacity(0.4), radius: 4)
                .accessibilityIdentifier("call-status")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OLMetric.horizontalPadding)
        .padding(.top, videoStage ? 8 : 0)
        .frame(maxHeight: videoStage ? nil : .infinity, alignment: videoStage ? .top : .center)
    }

    private var controlRow: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundButton(label: call.speakerOn ? "Speaker" : "Phone",
                        systemImage: call.speakerOn ? "speaker.wave.2.fill" : "iphone",
                        on: call.speakerOn) { call.toggleSpeaker() }
            if call.cameraOn {
                RoundButton(label: "Flip", systemImage: "arrow.triangle.2.circlepath") { call.flip() }
            }
            RoundButton(label: call.cameraOn ? "Camera" : "Video",
                        systemImage: call.cameraOn ? "video.fill" : "video.slash.fill",
                        on: call.cameraOn, enabled: call.canToggleVideo || call.phase == .calling || call.phase == .connecting || call.phase == .active) {
                call.toggleVideo()
            }
            RoundButton(label: call.muted ? "Unmute" : "Mute",
                        systemImage: call.muted ? "mic.slash.fill" : "mic.fill",
                        on: call.muted) { call.toggleMute() }
            RoundButton(label: "End call", systemImage: "phone.down.fill", fill: OLColor.end) { call.end() }
        }
        .padding(.horizontal, 16)
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

struct Pip: View {
    let view: UIView?
    var mirrored: Bool
    let size: CGSize
    let onSwap: () -> Void
    @State private var corner = "tr"
    @State private var drag: CGSize = .zero
    @State private var moving = false

    private var origin: CGPoint {
        let w = OLMetric.pipWidth
        let h = OLMetric.pipHeight
        let x: CGFloat = corner.hasSuffix("l") ? OLMetric.pipInset : size.width - w - OLMetric.pipInset
        let y: CGFloat = corner.hasPrefix("t") ? OLMetric.pipTop : size.height - h - OLMetric.pipBottomReserve
        return CGPoint(x: x, y: y)
    }

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
        .offset(x: origin.x + drag.width, y: origin.y + drag.height)
        .gesture(
            DragGesture()
                .onChanged { v in
                    moving = true
                    drag = v.translation
                }
                .onEnded { v in
                    let cx = origin.x + v.translation.width + OLMetric.pipWidth / 2
                    let cy = origin.y + v.translation.height + OLMetric.pipHeight / 2
                    if hypot(v.translation.width, v.translation.height) < 6 {
                        onSwap()
                    } else {
                        let tb = cy < size.height / 2 ? "t" : "b"
                        let lr = cx < size.width / 2 ? "l" : "r"
                        corner = tb + lr
                    }
                    drag = .zero
                    moving = false
                }
        )
        .animation(moving ? nil : .spring(response: 0.26, dampingFraction: 0.85), value: corner)
        .accessibilityIdentifier("call-pip")
    }
}

struct RoundButton: View {
    let label: String
    var systemImage: String? = nil
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
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: OLMetric.buttonIconSize, weight: .regular))
                            .foregroundColor(fill != nil ? .white : (on ? OLColor.buttonOnIcon : .white))
                    } else {
                        Text(label)
                            .font(.system(size: OLMetric.buttonLabelSize))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: size, height: size)
                Text(label)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundColor(OLColor.label)
                    .lineLimit(1)
                    .frame(maxWidth: 76)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : OLMetric.disabledOpacity)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }
}
