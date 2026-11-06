// Open Lounge PJSIP media engine (pjproject 2.17) via the OLPjsip C shim. One path for every call.
// Rules: never calls AVAudioSession.setActive; sound device opened only after CallKit didActivate AND the
// session is confirmed active; full teardown on every call end. SRTP SDES mandatory (keys only in a=crypto).
// Linphone cut (7af9794): main-thread open, resetForNewCall, no empty-route early return.
// Claude instrument: log which path returns PJMEDIA_EAUD_INIT (420003).
import AVFoundation
import UIKit

public final class PJSIPEngine {
  public static let shared = PJSIPEngine()
  public private(set) var audioRunning = false
  /// CallKit's audio session is active (didActivate seen, no didDeactivate since). Survives leg restarts/teardown:
  /// CallKit never re-sends didActivate for the same call, so a leg (re)started after activation must reopen sound
  /// itself (root cause of the Nov 4 iPhone<->Android one-way/no-audio: sfuStop tore the sound device down after
  /// didActivate and nothing reopened it, so the iPhone never captured/sent and never played).
  public private(set) var sessionActive = false
  private let q = DispatchQueue(label: "ol.pjsip.engine", qos: .userInitiated)
  private var lastSoundPath = "ensureSound"

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
      self.ensureSoundLocked(path: "didActivate")
      // If open failed (empty route), one retry on next routeChange is handled by reopenSound from the owner.
      if !self.audioRunning {
        self.q.asyncAfter(deadline: .now() + 0.02) { [weak self] in
          DispatchQueue.main.async { self?.ensureSoundLocked(path: "didActivate-retry") }
        }
      }
      _ = session
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  /// Open the sound device iff CallKit has activated the session (never activates the session itself).
  public func ensureSound(path: String = "ensureSound") {
    let work = { self.ensureSoundLocked(path: path) }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  private func ensureSoundLocked(path: String = "ensureSound") {
    guard sessionActive, !audioRunning else { return }
    lastSoundPath = path
    start()
    let status = ol_pjsip_open_sound()
    let eaud: String
    switch status {
    case 420003, -201: eaud = "PJMEDIA_EAUD_INIT"
    case 420001: eaud = "PJMEDIA_EAUD_ERR"
    case 420002: eaud = "PJMEDIA_EAUD_SYSERR"
    case 420004: eaud = "PJMEDIA_EAUD_INVDEV"
    case 420005: eaud = "PJMEDIA_EAUD_NODEV"
    case 420007: eaud = "PJMEDIA_EAUD_NOTREADY"
    case 0: eaud = "ok"
    default: eaud = "other"
    }
    let net = AVAudioSession.sharedInstance().currentRoute.outputs.first.map { $0.portType.rawValue } ?? "none"
    OLCallDiskLog.shared.mark("open-sound-result", "path=\(path) status=\(status) eaud=\(eaud) model=\(UIDevice.current.model) net=\(net)")
    if status == 0 { audioRunning = true }
    else { NSLog("[OLSound] openSound FAIL path=%@ status=%d eaud=%@ net=%@", path, status, eaud, net) }
  }

  /// b83 onMediaServicesReset / interruption-ended: close and reopen inside the still-active CallKit session.
  public func reopenSound() {
    let work = {
      guard self.sessionActive else { return }
      if self.audioRunning { ol_pjsip_close_sound(); self.audioRunning = false }
      self.ensureSoundLocked(path: "reopenSound")
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
