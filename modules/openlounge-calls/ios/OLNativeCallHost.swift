import UIKit
import SwiftUI
import Combine

/// Native call host (Claude step 5 first cut): SwiftUI phases over the RN/WebView root.
/// CallKit remains incoming authority. Four phases: incoming / outgoing / active / ended.
/// No RN/WebView paints the 1:1 call. Full CallController wiring comes later.
@MainActor
public final class OLNativeCallHost {
  public static let shared = OLNativeCallHost()
  public enum Phase: String { case incoming, outgoing, active, ended }

  private weak var presenter: UIViewController?
  private var host: UIHostingController<OLNativeCallView>?
  private var model = OLNativeCallModel()

  public func attach(to vc: UIViewController) { presenter = vc }

  public func present(callId: String, name: String, photoURL: String?, video: Bool, phase: Phase) {
    model.callId = callId; model.name = name; model.photoURL = photoURL; model.video = video; model.phase = phase
    model.status = statusText(phase)
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
    host?.rootView = OLNativeCallView(model: model)
    if phase == .ended {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.dismiss() }
    }
  }

  public func dismiss() {
    host?.dismiss(animated: true)
    host = nil
  }

  private func statusText(_ p: Phase) -> String {
    switch p {
    case .incoming: return "Incoming call"
    case .outgoing: return "Calling…"
    case .active: return ""
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
}

struct OLNativeCallView: View {
  @ObservedObject var model: OLNativeCallModel
  var body: some View {
    ZStack {
      Color(red: 0.043, green: 0.071, blue: 0.125).ignoresSafeArea() // #0b1220
      VStack(spacing: 16) {
        Spacer()
        Text(initials(model.name))
          .font(.system(size: 40, weight: .semibold))
          .foregroundColor(.white)
          .frame(width: 140, height: 140)
          .background(Color.white.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous)) // squircle-ish
        Text(model.name.isEmpty ? "Open Lounge" : model.name)
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(.white)
        Text(model.status)
          .font(.system(size: 15, weight: .regular))
          .foregroundColor(.white.opacity(0.8))
        Spacer()
        HStack(spacing: 18) {
          if model.phase == .incoming {
            roundBtn("Decline", color: Color(red: 0.937, green: 0.267, blue: 0.267)) {
              OLCallManager.shared.endFromApp()
              OLNativeCallHost.shared.dismiss()
            }
            roundBtn("Accept", color: Color(red: 0.063, green: 0.725, blue: 0.506)) {
              OLNativeCallHost.shared.update(phase: .active)
            }
          } else {
            roundBtn(model.speaker ? "Speaker" : "Earpiece", color: Color.white.opacity(0.15)) {
              model.speaker.toggle()
            }
            roundBtn(model.muted ? "Unmute" : "Mute", color: Color.white.opacity(0.15)) {
              model.muted.toggle()
              NativeCallMedia.shared.setMute(model.muted)
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
