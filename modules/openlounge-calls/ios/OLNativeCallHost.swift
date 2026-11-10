import OpenLoungeCallEngine
import UIKit
import SwiftUI
import Combine

/// Native call host (Claude step 5): SwiftUI phases over the RN/WebView root.
/// CallKit remains incoming authority. Four phases: incoming / outgoing / active / ended.
/// No RN/WebView paints the 1:1 call. Controls wired to OLCallManager + OLAudioSessionOwner.
@MainActor
public final class OLNativeCallHost {
  public static let shared = OLNativeCallHost()
  public enum Phase: String { case incoming, outgoing, active, ended }

  private weak var presenter: UIViewController?
  private var host: UIHostingController<OLNativeCallView>?
  private var model = OLNativeCallModel()
  private var timer: Timer?
  private var connectedAt: Date?

  public func attach(to vc: UIViewController) { presenter = vc }

  public func present(callId: String, name: String, photoURL: String?, video: Bool, phase: Phase) {
    model.callId = callId; model.name = name; model.photoURL = photoURL; model.video = video; model.phase = phase
    model.status = statusText(phase)
    if phase == .active { startTimerIfNeeded() }
    guard let presenter else {
      NSLog("[OLCallUI] no presenter yet; queued phase=%@", phase.rawValue)
      return
    }
    if host == nil {
      let hc = UIHostingController(rootView: OLNativeCallView(model: model))
      hc.modalPresentationStyle = .overFullScreen
      hc.view.backgroundColor = .clear
      host = hc
      presenter.present(hc, animated: true)
    } else {
      host?.rootView = OLNativeCallView(model: model)
    }
  }

  public func update(phase: Phase) {
    model.phase = phase
    model.status = statusText(phase)
    if phase == .active { startTimerIfNeeded() }
    host?.rootView = OLNativeCallView(model: model)
    if phase == .ended {
      stopTimer()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.dismiss() }
    }
  }

  // olcall (tgcalls) video: VideoMetalView / sample-buffer views from TgVoipWebrtc, placed in this screen's own frames.
  public func setVideoView(_ v: UIView, local: Bool) {
    if local { model.localView = v } else { model.remoteView = v }
    host?.rootView = OLNativeCallView(model: model)
  }
  public func setRemoteVideoActive(_ on: Bool) {
    guard model.remoteVideoOn != on else { return }
    model.remoteVideoOn = on
    host?.rootView = OLNativeCallView(model: model)
  }
  public func clearVideoViews() {
    model.localView = nil; model.remoteView = nil; model.remoteVideoOn = false
    host?.rootView = OLNativeCallView(model: model)
  }

  public func dismiss() {
    stopTimer()
    host?.dismiss(animated: true)
    host = nil
    connectedAt = nil
  }

  private func startTimerIfNeeded() {
    if connectedAt == nil { connectedAt = Date() }
    stopTimer()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let t0 = self.connectedAt else { return }
        let s = Int(Date().timeIntervalSince(t0))
        let m = s / 60; let r = s % 60
        self.model.status = String(format: "%d:%02d", m, r)
        self.host?.rootView = OLNativeCallView(model: self.model)
      }
    }
  }

  private func stopTimer() {
    timer?.invalidate(); timer = nil
  }

  private func statusText(_ p: Phase) -> String {
    switch p {
    case .incoming: return "Incoming call"
    case .outgoing: return "Calling…"
    case .active: return connectedAt == nil ? "Connected" : model.status
    case .ended: return "Call ended"
    }
  }
}

final class OLNativeCallModel: ObservableObject {
  @Published var callId = ""
  @Published var name = ""
  @Published var photoURL: String?
  @Published var video = false
  @Published var phase: OLNativeCallHost.Phase = .outgoing
  @Published var status = "Calling…"
  @Published var muted = false
  @Published var speaker = false
  @Published var camOn = false
  /// olcall only: far side's video (shown full screen while active) and the local preview (squircle).
  @Published var remoteView: UIView?
  @Published var localView: UIView?
  @Published var remoteVideoOn = false
}

/// Hosts a UIKit video view (tgcalls VideoMetalView) inside the SwiftUI call screen.
struct OLHostedVideoView: UIViewRepresentable {
  let view: UIView
  func makeUIView(context: Context) -> UIView {
    let c = UIView()
    c.backgroundColor = .black
    c.clipsToBounds = true
    return c
  }
  func updateUIView(_ c: UIView, context: Context) {
    if view.superview !== c {
      c.subviews.forEach { $0.removeFromSuperview() }
      view.frame = c.bounds
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      c.addSubview(view)
    }
  }
}

struct OLNativeCallView: View {
  @ObservedObject var model: OLNativeCallModel
  var body: some View {
    ZStack {
      Color(red: 0.043, green: 0.071, blue: 0.125).ignoresSafeArea() // #0b1220
      if model.remoteVideoOn, let rv = model.remoteView {
        OLHostedVideoView(view: rv).ignoresSafeArea()
      }
      if model.camOn, let lv = model.localView {
        VStack {
          HStack {
            Spacer()
            OLHostedVideoView(view: lv)
              .frame(width: 110, height: 160)
              .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
              .padding(.top, 12).padding(.trailing, 16)
          }
          Spacer()
        }
      }
      VStack(spacing: 16) {
        Spacer()
        ZStack {
          Text(initials(model.name))
            .font(.system(size: 40, weight: .semibold))
            .foregroundColor(.white)
          if let urlStr = model.photoURL, let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
              switch phase {
              case .success(let img): img.resizable().scaledToFill()
              default: Color.clear
              }
            }
          }
        }
        .frame(width: 140, height: 140)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        Text(model.name.isEmpty ? "Open Lounge" : model.name)
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(.white)
        Text(model.status)
          .font(.system(size: 15, weight: .regular).monospacedDigit())
          .foregroundColor(.white.opacity(0.8))
        Spacer()
        HStack(spacing: 18) {
          if model.phase == .incoming {
            roundBtn("Decline", color: Color(red: 0.937, green: 0.267, blue: 0.267)) {
              OLCallManager.shared.declineFromApp(model.callId)
              OLNativeCallHost.shared.update(phase: .ended)
            }
            roundBtn("Accept", color: Color(red: 0.063, green: 0.725, blue: 0.506)) {
              OLCallManager.shared.answerFromApp(model.callId)
              OLNativeCallHost.shared.update(phase: .active)
            }
          } else {
            roundBtn(model.speaker ? "Speaker" : "Earpiece", color: Color.white.opacity(0.15)) {
              model.speaker.toggle()
              OLCallManager.shared.setSpeaker(model.speaker)
            }
            if model.video {
              roundBtn(model.camOn ? "Stop video" : "Video", color: Color.white.opacity(0.15)) {
                model.camOn.toggle()
                OLCallManager.shared.setCamera(on: model.camOn)
              }
            }
            roundBtn(model.muted ? "Unmute" : "Mute", color: Color.white.opacity(0.15)) {
              model.muted.toggle()
              OLCallManager.shared.setMediaMuted(model.muted)
            }
            roundBtn("End", color: Color(red: 0.937, green: 0.267, blue: 0.267)) {
              OLCallManager.shared.endFromApp()
              OLNativeCallHost.shared.update(phase: .ended)
            }
          }
        }
        .padding(.bottom, 36)
      }
    }
    .onAppear { if model.video { model.camOn = true } }
  }

  private func initials(_ name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
    let s = parts.map { String($0.prefix(1)).uppercased() }.joined()
    return s.isEmpty ? "OL" : s
  }

  private func roundBtn(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.9))
        .frame(width: 72, height: 72)
        .background(color)
        .clipShape(Circle())
    }
  }
}
