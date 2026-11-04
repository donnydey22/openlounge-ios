// Open Lounge PJSIP media engine (pjproject 2.17) via the OLPjsip C shim. One path for every call.
// Rules: never calls AVAudioSession.setActive; sound device opened only after CallKit didActivate AND the
// session is confirmed active; full teardown on every call end. SRTP SDES mandatory (keys only in a=crypto).
import AVFoundation

public final class PJSIPEngine {
  public static let shared = PJSIPEngine()
  public private(set) var audioRunning = false
  /// CallKit's audio session is active (didActivate seen, no didDeactivate since). Survives leg restarts/teardown:
  /// CallKit never re-sends didActivate for the same call, so a leg (re)started after activation must reopen sound
  /// itself (root cause of the Nov 4 iPhone<->Android one-way/no-audio: sfuStop tore the sound device down after
  /// didActivate and nothing reopened it, so the iPhone never captured/sent and never played).
  public private(set) var sessionActive = false

  @discardableResult public func start() -> Int32 { ol_pjsip_start(1, 16, 50) } // adaptive jbuf, progressive discard

  /// Called only from provider(_:didActivate:).
  public func audioSessionDidActivate(_ session: AVAudioSession) {
    guard !session.currentRoute.outputs.isEmpty else { return } // session confirmed active by CallKit
    sessionActive = true
    ensureSound()
  }

  /// Open the sound device iff CallKit has activated the session (never activates the session itself).
  public func ensureSound() {
    guard sessionActive, !audioRunning else { return }
    start()
    if ol_pjsip_open_sound() == 0 { audioRunning = true }
  }

  /// b83 onMediaServicesReset / interruption-ended (Telegram: mediaServicesWereLost → setup + activate again):
  /// the old audio unit is dead, so close and reopen the sound device inside the still-active CallKit session.
  public func reopenSound() {
    guard sessionActive else { return }
    if audioRunning { ol_pjsip_close_sound(); audioRunning = false }
    ensureSound()
  }

  public func audioSessionDidDeactivate() { ol_pjsip_close_sound(); audioRunning = false; sessionActive = false }

  /// Video call start: QuickHD burst (1080p/2.5 Mbps) for 4 s, then steady 720p/1.2 Mbps (tune from prod data).
  public func startVideoBurst() {
    start(); ol_pjsip_video_quickhd()
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { ol_pjsip_video_steady() }
  }

  /// Full teardown on every call end so a redial starts from zero.
  public func teardown() { ol_pjsip_teardown(); audioRunning = false }
}
