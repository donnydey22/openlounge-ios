// The 5-step SFU media setup, moved 1:1 from the deleted src/pjsipMedia.ts:65-99 (b103) into Swift next to
// PJSIPEngine, over the app's own CallSignalClient instead of the page relay:
//   ms:join -> ms:plain:create -> ms:plain:connect {srtpParameters} -> ms:plain:produce {audio, ssrc, PT 111}
//   -> ms:plain:consume, then the PJSIP SRTP leg (ol_sfu_audio_start). Video: own "video" PlainTransport + key,
//   3 simulcast SSRCs, H.264 PT 102 (pjsipMedia.ts:33-49), consume polled every 1.5 s until the peer's video exists.
// Audio is never started by this file: the sound device opens only from CallKit didActivate
// (PJSIPEngine.audioSessionDidActivate); a leg started after activation reopens it (PJSIPEngine.ensureSound).
// Telegram does the same: OngoingCallContext is built with audioSessionActive = CallKit's signal
// (tgios PresentationCall.swift:410-437, :1218-1225; CallKitIntegration.swift:411-414).
import Foundation
import Security

public final class NativeCallMedia {
  public static let shared = NativeCallMedia()
  private static let SRTP = "AES_CM_128_HMAC_SHA1_80"

  private struct Leg { let callId: String; let ip: String; let port: Int; let tx: String; let rx: String; let ssrc: UInt32; let rxPt: Int }
  private var leg: Leg?
  private var videoStarted = false
  private var videoCallId: String?
  private var consumePoll: Timer?
  private var connecting: String?
  /// (callId, local camera on, remote video arrived) for the app's video views; main queue
  public var onVideo: ((String, Bool, Bool) -> Void)?
  private var localOn = false
  private var remoteOn = false

  public static func newSrtpKey() -> String {
    var b = [UInt8](repeating: 0, count: 30)
    _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
    return Data(b).base64EncodedString()
  }
  private static func rnd(_ base: UInt32) -> UInt32 { base + UInt32.random(in: 0..<1_000_000) }

  /// pjsipMedia.ts op "connect" (:65-99). Idempotent for the same live call. Main queue.
  public func connect(_ sig: CallSignalClient, callId: String, video: Bool, done: @escaping (Bool, String?) -> Void) {
    if leg?.callId == callId || connecting == callId { done(true, nil); return }
    connecting = callId
    let d: [String: Any] = ["callId": callId]
    let tx = Self.newSrtpKey(), ssrc = Self.rnd(100_000)
    func fail(_ step: String, _ r: [String: Any]) {
      connecting = nil
      NSLog("[OLMedia] %@ failed: %@", step, (r["error"] as? String) ?? "?")
      done(false, "\(step): \((r["error"] as? String) ?? "failed")")
    }
    sig.request("ms:join", d) { [weak self] r in
      guard let self, self.connecting == callId else { return }
      guard r["ok"] as? Bool == true else { return fail("ms:join", r) }
      sig.request("ms:plain:create", d) { c in
        guard self.connecting == callId else { return }
        guard c["ok"] as? Bool == true, let ip = c["ip"] as? String, let port = (c["port"] as? NSNumber)?.intValue else { return fail("ms:plain:create", c) }
        let rx = ((c["srtpParameters"] as? [String: Any])?["keyBase64"] as? String) ?? ""
        sig.request("ms:plain:connect", ["callId": callId, "srtpParameters": ["cryptoSuite": Self.SRTP, "keyBase64": tx]]) { k in
          guard self.connecting == callId else { return }
          guard k["ok"] as? Bool == true else { return fail("ms:plain:connect", k) }
          sig.request("ms:plain:produce", ["callId": callId, "kind": "audio", "ssrc": ssrc, "payloadType": 111]) { p in
            guard self.connecting == callId else { return }
            guard p["ok"] as? Bool == true else { return fail("ms:plain:produce", p) }
            sig.request("ms:plain:consume", d) { cons in
              guard self.connecting == callId else { return }
              let a = (cons["consumers"] as? [[String: Any]])?.first { $0["kind"] as? String == "audio" }
              let l = Leg(callId: callId, ip: ip, port: port, tx: tx, rx: rx, ssrc: ssrc, rxPt: (a?["payloadType"] as? NSNumber)?.intValue ?? 100)
              self.leg = l
              self.connecting = nil
              let rc = self.startLeg(l)
              if rc != 0 { self.leg = nil; done(false, "pjsip audio leg start failed: \(rc)"); return }
              done(true, nil)
              if video { self.startVideo(sig, callId: callId, cameraOn: true) }
            }
          }
        }
      }
    }
  }

  @discardableResult private func startLeg(_ l: Leg) -> Int32 {
    PJSIPEngine.shared.start()
    let r = ol_sfu_audio_start(l.ip, Int32(l.port), l.tx, l.rx, l.ssrc, 111, Int32(l.rxPt), 0)
    PJSIPEngine.shared.ensureSound() // leg (re)started after didActivate: reopen sound now (no-op before activation)
    return r
  }

  /// pjsipMedia.ts startVideo (:33-49) + the camera-open retry while didActivate is pending (:91-93).
  public func startVideo(_ sig: CallSignalClient, callId: String, cameraOn: Bool) {
    guard !videoStarted, videoCallId != callId else { return }
    videoCallId = callId
    let d: [String: Any] = ["callId": callId, "purpose": "video"]
    let tx = Self.newSrtpKey()
    let ssrcs = [Self.rnd(5_000_000), Self.rnd(6_000_000), Self.rnd(7_000_000)]
    sig.request("ms:plain:create", d) { [weak self] c in
      guard let self, self.videoCallId == callId else { return }
      guard c["ok"] as? Bool == true, let ip = c["ip"] as? String, let port = (c["port"] as? NSNumber)?.intValue else { NSLog("[OLMedia] video plain:create failed"); return }
      let rx = ((c["srtpParameters"] as? [String: Any])?["keyBase64"] as? String) ?? ""
      sig.request("ms:plain:connect", ["callId": callId, "purpose": "video", "srtpParameters": ["cryptoSuite": Self.SRTP, "keyBase64": tx]]) { _ in
        guard self.videoCallId == callId else { return }
        let r = OLCallVideo.shared.start(ip: ip, port: port, txKey: tx, rxKey: rx, ssrcs: ssrcs, pt: 102)
        if r != 0 { NSLog("[OLMedia] video leg start failed: %d", r); return }
        self.videoStarted = true
        sig.request("ms:plain:produce", ["callId": callId, "kind": "video", "ssrcs": ssrcs, "payloadType": 102, "codec": "h264", "platform": "ios"]) { _ in }
        OLCallVideo.shared.onRemoteFirstFrame = { [weak self] in DispatchQueue.main.async { self?.remoteOn = true; self?.report() } }
        let consume = { [weak self] in
          guard let self, self.videoCallId == callId, !self.remoteOn else { self?.consumePoll?.invalidate(); return }
          sig.request("ms:plain:consume", d) { x in
            if (x["consumers"] as? [[String: Any]])?.contains(where: { $0["kind"] as? String == "video" }) == true { self.consumePoll?.invalidate(); self.consumePoll = nil }
          }
        }
        self.consumePoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in consume() }
        consume()
        if cameraOn { self.openCamera(tries: 20) }
      }
    }
  }

  /// camera opens only after didActivate; the native gate throws until then, so retry briefly (pjsipMedia.ts:91-93)
  private func openCamera(tries: Int) {
    do { try OLCallVideo.shared.camera(on: true, facing: "user"); localOn = true; report() }
    catch { if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.openCamera(tries: tries - 1) } } }
  }

  private func report() { if let id = videoCallId { onVideo?(id, localOn, remoteOn) } }

  public func setMute(_ muted: Bool) { _ = ol_sfu_set_mute(muted ? 1 : 0) }

  /// pjsipMedia.ts onNetworkChange (:96-98): same tuple and keys, fresh socket on the new interface.
  public func networkChanged() { if let l = leg { ol_sfu_stop(); startLeg(l) } }

  /// pjsipMedia.ts closeAll (:92-95) + sfuStop/teardown. Every call end.
  public func closeAll() {
    consumePoll?.invalidate(); consumePoll = nil
    OLCallVideo.shared.onRemoteFirstFrame = nil
    if videoStarted { OLCallVideo.shared.stop() }
    let hadVideo = videoCallId
    videoStarted = false; localOn = false; remoteOn = false; videoCallId = nil
    if let id = hadVideo { onVideo?(id, false, false) }
    leg = nil; connecting = nil
    ol_sfu_stop(); PJSIPEngine.shared.teardown()
  }
}
