// Open Lounge PJSIP media engine (pjproject 2.17) via the OLPjsip C shim. One path for every call.
// Rules: never calls AVAudioSession.setActive; sound device opened only after CallKit didActivate AND the
// session is confirmed active; full teardown on every call end. SRTP SDES mandatory (keys only in a=crypto).
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

  @discardableResult public func start() -> Int32 { ol_pjsip_start(1, 16, 50) } // adaptive jbuf, progressive discard

  /// Called only from provider(_:didActivate:).
  public func audioSessionDidActivate(_ session: AVAudioSession) {
    guard !session.currentRoute.outputs.isEmpty else { return } // session confirmed active by CallKit
    sessionActive = true
    ensureSound(path: "didActivate")
  }

  /// Open the sound device iff CallKit has activated the session (never activates the session itself).
  /// Logs which caller path hit PJMEDIA_EAUD_INIT (420003 / legacy -201) for Claude instrumentation.
  public func ensureSound(path: String = "ensureSound") {
    guard sessionActive, !audioRunning else { return }
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
