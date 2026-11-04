// Open Lounge PJSIP media engine (pjproject 2.17) via the OLPjsip C shim. One path for every call.
// Rules: audio session category set only in CallKit didActivate (build 83 order); every pjlib call runs on `q`, the
// engine's own serial queue (b93 SIGABRT: pjlib reached from the JS thread); sound device opened only after CallKit didActivate AND the
// session is confirmed active; full teardown on every call end. SRTP SDES mandatory (keys only in a=crypto).
import AVFoundation

public final class PJSIPEngine {
  public static let shared = PJSIPEngine()
  /// The engine's thread: all pjlib work is serialized here (the C shim also registers whichever thread GCD uses).
  public let q = DispatchQueue(label: "openlounge.pjsip.engine")
  /// Engine -> UI state (existing native->JS event path): RTP counters pushed from the engine queue, never polled.
  public var onAudioStats: (([String: Any]) -> Void)?
  private var statsTimer: DispatchSourceTimer?
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
    // build 83 session setup (playAndRecord / voiceChat), only here: CallKit has just activated the session
    do { try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth]) }
    catch { NSLog("[OLCalls] pjsip session category failed: %@", error.localizedDescription) }
    q.sync { sessionActive = true; ensureSound() }
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
    q.sync {
      guard sessionActive else { return }
      if audioRunning { ol_pjsip_close_sound(); audioRunning = false }
      ensureSound()
    }
  }

  public func audioSessionDidDeactivate() { q.sync { ol_pjsip_close_sound(); audioRunning = false; sessionActive = false } }

  /// Audio leg start/stop on the engine queue. While a leg runs, the engine pushes its RTP counters once a second.
  public func audioStart(ip: String, port: Int, txKey: String, rxKey: String, ssrc: UInt32, txPt: Int32, rxPt: Int32) -> Int {
    q.sync {
      start()
      let r = Int(ol_sfu_audio_start(ip, Int32(port), txKey, rxKey, ssrc, txPt, rxPt, 0))
      ensureSound() // leg (re)started after didActivate: reopen sound now
      if r == 0 && statsTimer == nil {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
          var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0
          guard ol_sfu_stats(&rx, &lost, &tx) == 0 else { return }
          self?.onAudioStats?(["rx": Int(rx), "lost": Int(lost), "tx": Int(tx), "video": OLCallVideo.shared.stats()])
        }
        statsTimer = t; t.resume()
      }
      return r
    }
  }
  public func audioStop() { q.sync { statsTimer?.cancel(); statsTimer = nil; ol_sfu_stop(); teardownLocked() } }
  public func setMute(_ muted: Bool) -> Int { q.sync { Int(ol_sfu_set_mute(muted ? 1 : 0)) } }

  /// Video call start: QuickHD burst (1080p/2.5 Mbps) for 4 s, then steady 720p/1.2 Mbps (tune from prod data).
  public func startVideoBurst() {
    q.sync { start(); _ = ol_pjsip_video_quickhd() }
    q.asyncAfter(deadline: .now() + 4) { _ = ol_pjsip_video_steady() }
  }

  /// Full teardown on every call end so a redial starts from zero.
  public func teardown() { q.sync { statsTimer?.cancel(); statsTimer = nil; teardownLocked() } }
  private func teardownLocked() { ol_pjsip_teardown(); audioRunning = false }
}
