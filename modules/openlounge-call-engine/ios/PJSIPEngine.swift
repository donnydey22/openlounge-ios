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
  private let q = DispatchQueue(label: "ol.pjsip.engine", qos: .userInitiated)

  @discardableResult public func start() -> Int32 { ol_pjsip_start(1, 16, 50) } // adaptive jbuf, progressive discard

  /// Reset flag at CXStart / CXAnswer so a late didDeactivate from the previous call cannot leave sound open early.
  public func resetForNewCall() {
    let work = { self.sessionActive = false; if self.audioRunning { ol_pjsip_close_sound(); self.audioRunning = false } }
    if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
  }

  /// Called only from provider(_:didActivate:). Empty route no longer blocks the flag (Claude: permanent stuck-silent).
  public func audioSessionDidActivate(_ session: AVAudioSession) {
    let work = {
      self.sessionActive = true
      self.ensureSoundLocked()
      // If open failed (empty route), one retry on next routeChange is handled by reopenSound from the owner.
      if !self.audioRunning {
        self.q.asyncAfter(deadline: .now() + 0.02) { [weak self] in
          DispatchQueue.main.async { self?.ensureSoundLocked() }
        }
      }
      _ = session
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  /// Open the sound device iff CallKit has activated the session (never activates the session itself).
  public func ensureSound() {
    let work = { self.ensureSoundLocked() }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  private func ensureSoundLocked() {
    guard sessionActive, !audioRunning else { return }
    start()
    if ol_pjsip_open_sound() == 0 { audioRunning = true }
  }

  /// b83 onMediaServicesReset / interruption-ended: close and reopen inside the still-active CallKit session.
  public func reopenSound() {
    let work = {
      guard self.sessionActive else { return }
      if self.audioRunning { ol_pjsip_close_sound(); self.audioRunning = false }
      self.ensureSoundLocked()
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  public func audioSessionDidDeactivate() {
    let work = { ol_pjsip_close_sound(); self.audioRunning = false; self.sessionActive = false }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  /// Video call start: QuickHD burst — precondition audioRunning (camera after sound).
  public func startVideoBurst() {
    guard audioRunning else { return }
    start(); ol_pjsip_video_quickhd()
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { ol_pjsip_video_steady() }
  }

  /// Full teardown on every call end so a redial starts from zero.
  public func teardown() { ol_pjsip_teardown(); audioRunning = false }
}
