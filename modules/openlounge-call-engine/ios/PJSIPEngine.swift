// Open Lounge PJSIP media engine (pjproject 2.17) via the OLPjsip C shim. One path for every call.
// Rules: never calls AVAudioSession.setActive; sound device opened only after CallKit didActivate AND the
// session is confirmed active; full teardown on every call end. SRTP SDES mandatory (keys only in a=crypto).
import AVFoundation

public final class PJSIPEngine {
  public static let shared = PJSIPEngine()
  public private(set) var audioRunning = false

  @discardableResult public func start() -> Int32 { ol_pjsip_start(1, 16, 50) } // adaptive jbuf, progressive discard

  /// Called only from provider(_:didActivate:).
  public func audioSessionDidActivate(_ session: AVAudioSession) {
    guard !audioRunning else { return }
    guard !session.currentRoute.outputs.isEmpty else { return } // session confirmed active by CallKit
    start()
    if ol_pjsip_open_sound() == 0 { audioRunning = true }
  }

  public func audioSessionDidDeactivate() { ol_pjsip_close_sound(); audioRunning = false }

  /// Full teardown on every call end so a redial starts from zero.
  public func teardown() { ol_pjsip_teardown(); audioRunning = false }
}
