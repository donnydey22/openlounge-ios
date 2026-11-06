// PJSIPEngine — TRANSPORT/VIDEO SHIM ONLY (signal-identical-calling). The PJSIP sound-device path
// (ol_pjsip_open_sound / close_sound, ensureSound, reopenSound, didActivate/didDeactivate hooks, 420003/-201 mapping)
// is DELETED from calling. Call audio is owned solely by OLCallAudioEngine (WebRTC manual audio) after
// OLAudioSessionOwner forwards CallKit didActivate. This file is removed entirely once the OL rtcSession
// WebRTC transport replaces ol_sfu/ol_p2p (plan §1 row 2).
import Foundation

public final class PJSIPEngine {
  public static let shared = PJSIPEngine()

  @discardableResult public func start() -> Int32 { ol_pjsip_start(1, 16, 50) }

  /// Video call start: QuickHD burst — precondition: call audio running in OLCallAudioEngine.
  public func startVideoBurst() {
    guard OLCallAudioEngine.shared.isRunning else { return }
    start(); ol_pjsip_video_quickhd()
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { ol_pjsip_video_steady() }
  }

  /// Full teardown on every call end so a redial starts from zero.
  public func teardown() { ol_pjsip_teardown() }
}
