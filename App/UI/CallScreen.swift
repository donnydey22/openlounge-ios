// The one-to-one call screen. Layout from d6135f0: name + status centred near the top, one row of
// round buttons at the bottom (Video, Speaker, Mute, End), with the 9c851a0 squircle avatar above
// the name. In a video call the far side's video fills the stage and the local preview sits top-right.
import SwiftUI

struct CallScreen: View {
    @ObservedObject var call: CallController

    var body: some View {
        GeometryReader { geo in
            ZStack {
                OLColor.stage.ignoresSafeArea()
                if call.remoteVideoOn, let remote = call.remoteVideoView {
                    VideoSurface(view: remote).ignoresSafeArea()
                }
                if call.cameraOn, let local = call.localVideoView {
                    VStack {
                        HStack {
                            Spacer()
                            VideoSurface(view: local)
                                .frame(width: 96, height: 136)
                                .squircle(OLMetric.cardCorner)
                                .padding(.trailing, 16)
                        }
                        Spacer()
                    }
                    .padding(.top, 12)
                }
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if !call.remoteVideoOn {
                            Avatar(name: call.peerName, photoURL: call.peerPhoto)
                                .padding(.bottom, OLMetric.avatarGap)
                        }
                        Text(call.peerName)
                            .font(.system(size: OLMetric.nameSize, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(call.statusText)
                            .font(.system(size: OLMetric.statusSize).monospacedDigit())
                            .foregroundColor(OLColor.status)
                            .padding(.top, OLMetric.statusGap)
                            .accessibilityIdentifier("call-status")
                    }
                    .padding(.horizontal, OLMetric.horizontalPadding)
                    .padding(.top, OLMetric.topMargin)
                    Spacer()
                    HStack(spacing: 0) {
                        RoundButton(label: "Video", on: call.cameraOn, enabled: call.canToggleVideo) { call.toggleVideo() }
                        RoundButton(label: call.speakerOn ? "Speaker\non" : "Speaker", on: call.speakerOn) { call.toggleSpeaker() }
                        RoundButton(label: call.muted ? "Muted" : "Mute", on: call.muted) { call.toggleMute() }
                        RoundButton(label: "End", fill: OLColor.end) { call.end() }
                    }
                    .padding(.bottom, OLMetric.rowBottom + geo.safeAreaInsets.bottom)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .accessibilityIdentifier("call-screen")
    }
}

struct RoundButton: View {
    let label: String
    var on = false
    var enabled = true
    var fill: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: OLMetric.buttonLabelSize))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .frame(width: OLMetric.buttonSize, height: OLMetric.buttonSize)
                .background(fill ?? (on ? OLColor.buttonOn : OLColor.button))
                .clipShape(Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : OLMetric.disabledOpacity)
        .padding(.horizontal, OLMetric.buttonGap)
        .accessibilityLabel(label.replacingOccurrences(of: "\n", with: " "))
    }
}
