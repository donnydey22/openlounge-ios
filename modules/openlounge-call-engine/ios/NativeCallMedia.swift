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
  /// direct = the peer is a phone: ONE path, the direct ICE link (our coturn is only an ICE candidate); no SFU leg and no
  /// switchover. Peer = browser: the SFU only. (Donny, 9:10 AM Nov 5 2026)
  public func connect(_ sig: CallSignalClient, callId: String, video: Bool, direct: Bool = false, done: @escaping (Bool, String?) -> Void) {
    // b107 scope: ONE path, the server route (SFU) for EVERY pairing; the direct hint is logged and ignored.
    if leg?.callId == callId || connecting == callId { done(true, nil); return }
    OLCallDiskLog.shared.begin(callId)
    OLCallDiskLog.shared.mark("connect", "video=\(video) directHint=\(direct) -> server route")
    sig.emit("call:diag", ["callId": callId, "ev": "calllog", "lines": OLCallDiskLog.shared.tail()])
    connecting = callId
    let d: [String: Any] = ["callId": callId]
    let tx = Self.newSrtpKey(), ssrc = Self.rnd(100_000)
    func fail(_ step: String, _ r: [String: Any]) {
      connecting = nil
      OLCallDiskLog.shared.mark("fail", "\(step): \((r["error"] as? String) ?? "?")")
      NSLog("[OLMedia] %@ failed: %@", step, (r["error"] as? String) ?? "?")
      done(false, "\(step): \((r["error"] as? String) ?? "failed")")
    }
    // a reply carrying an error is a failure even if ok=true (e.g. plain:produce "need 3 ssrcs")
    func good(_ r: [String: Any]) -> Bool { r["ok"] as? Bool == true && (r["error"] == nil || r["error"] is NSNull) }
    OLCallDiskLog.shared.mark("ms:join")
    sig.request("ms:join", d) { [weak self] r in
      guard let self, self.connecting == callId else { return }
      guard good(r) else { return fail("ms:join", r) }
      sig.request("ms:plain:create", d) { c in
        guard self.connecting == callId else { return }
        guard good(c), let ip = c["ip"] as? String, let port = (c["port"] as? NSNumber)?.intValue else { return fail("ms:plain:create", c) }
        let rx = ((c["srtpParameters"] as? [String: Any])?["keyBase64"] as? String) ?? ""
        sig.request("ms:plain:connect", ["callId": callId, "srtpParameters": ["cryptoSuite": Self.SRTP, "keyBase64": tx]]) { k in
          guard self.connecting == callId else { return }
          guard good(k) else { return fail("ms:plain:connect", k) }
          sig.request("ms:plain:produce", ["callId": callId, "kind": "audio", "ssrc": ssrc, "payloadType": 111]) { p in
            guard self.connecting == callId else { return }
            guard good(p) else { return fail("ms:plain:produce", p) }
            sig.request("ms:plain:consume", d) { cons in
              guard self.connecting == callId else { return }
              guard good(cons) else { return fail("ms:plain:consume", cons) }
              let a = (cons["consumers"] as? [[String: Any]])?.first { $0["kind"] as? String == "audio" }
              let l = Leg(callId: callId, ip: ip, port: port, tx: tx, rx: rx, ssrc: ssrc, rxPt: (a?["payloadType"] as? NSNumber)?.intValue ?? 100)
              self.leg = l
              self.connecting = nil
              let rc = self.startLeg(l)
              OLCallDiskLog.shared.mark("leg-start", "rc=\(rc)")
              if rc != 0 { self.leg = nil; done(false, "pjsip audio leg start failed: \(rc)"); return }
              // connected means audio: report connected only once RTP flows both ways on the leg
              self.awaitTwoWay(callId: callId) { ok, why in
                if !ok { OLCallDiskLog.shared.mark("fail", "two-way: \(why)"); done(false, "two-way: \(why)"); return }
                done(true, nil)
                if video { self.startVideo(sig, callId: callId, cameraOn: true) }
              }
            }
          }
        }
      }
    }
  }

  /// >=10 RTP packets received AND sent on the leg (ol_sfu_stats) within 15 s, polled on main.
  private func awaitTwoWay(callId: String, t0: Date = Date(), _ cb: @escaping (Bool, String) -> Void) {
    guard leg?.callId == callId else { return cb(false, "leg closed") }
    var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0
    _ = ol_sfu_stats(&rx, &lost, &tx)
    if rx >= 10 && tx >= 10 { OLCallDiskLog.shared.mark("two-way", "rx=\(rx) tx=\(tx)"); return cb(true, "") }
    if Date().timeIntervalSince(t0) > 15 { OLCallDiskLog.shared.mark("two-way-timeout", "rx=\(rx) tx=\(tx)"); return cb(false, "no two-way audio rx=\(rx) tx=\(tx)") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.awaitTwoWay(callId: callId, t0: t0, cb) }
  }

  @discardableResult private func startLeg(_ l: Leg) -> Int32 {
    PJSIPEngine.shared.start()
    let r = ol_sfu_audio_start(l.ip, Int32(l.port), l.tx, l.rx, l.ssrc, 111, Int32(l.rxPt), 0)
    PJSIPEngine.shared.ensureSound() // leg (re)started after didActivate: reopen sound now (no-op before activation)
    return r
  }

  /// pjsipMedia.ts startVideo (:33-49) + the camera-open retry while didActivate is pending (:91-93).
  public func startVideo(_ sig: CallSignalClient, callId: String, cameraOn: Bool) {
    if direct { return startDirectVideo(callId: callId, cameraOn: cameraOn) }
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

  public func setMute(_ muted: Bool) { self.muted = muted; if p2p != .off { _ = ol_p2p_set_mute(muted ? 1 : 0) }; _ = ol_sfu_set_mute(muted ? 1 : 0) }

  /// pjsipMedia.ts onNetworkChange (:96-98): same tuple and keys, fresh socket on the new interface.
  public func networkChanged() {
    if direct { if p2pCfg != nil && p2p != .off { p2pRestart(tellPeer: true) }; return } // same single path, fresh ICE
    guard let l = leg else { return }
    if p2p == .live { _ = ol_p2p_activate(0) }
    if videoP2p { videoP2p = false; _ = ol_p2p_video_live(0) }
    ol_sfu_stop(); startLeg(l); if muted { _ = ol_sfu_set_mute(1) }
    if p2p == .trying || p2p == .live { p2pRestart(tellPeer: true) } // regather on network change (tgcalls :635-637)
  }

  /// pjsipMedia.ts closeAll (:92-95) + sfuStop/teardown. Every call end.
  public func closeAll() {
    consumePoll?.invalidate(); consumePoll = nil
    OLCallVideo.shared.onRemoteFirstFrame = nil
    if videoStarted { OLCallVideo.shared.stop() }
    let hadVideo = videoCallId
    videoStarted = false; localOn = false; remoteOn = false; videoCallId = nil
    if let id = hadVideo { onVideo?(id, false, false) }
    p2pStopAll()
    leg = nil; connecting = nil
    ol_sfu_stop(); PJSIPEngine.shared.teardown()
  }

  // ---- Phone-to-phone direct leg (ol_p2p.c, same file as Android 44). NO encryption: plain RTP over ICE.
  // Port of the b81046b/589ba6d controller (Android NativeCallMedia.kt 90670f7/0a1040a) to Swift for b104's native calls.
  // Connectivity = tgcalls 38dcea1 v2/NativeNetworkingImpl.cpp: :576-606 one allocator host+STUN+TURN, :596-601 relay-only,
  // :610-626 TURN from config (our coturn, logins from the existing call:turnRefresh), :635-637 regather on network change.
  // Video bundled on the same transport: InstanceV2Impl.cpp:460/:1135. Any failure -> the server route, which never stops
  // until the direct leg is proven both ways. Nothing here touches dial/ring/active/end or any UI.
  private enum P2p { case off, trying, live, failed }
  private struct P2pCfg { let offerer: Bool; let turn: String; let user: String; let pass: String; let tcp: Bool }
  private var p2p: P2p = .off
  private var p2pCfg: P2pCfg?
  private var pendingOffer: String?
  private var gen = 0
  private var muted = false
  private var lastRx: UInt32 = 0
  private var lastRxAt = Date()
  private var p2pCallId = ""
  private var videoP2p = false
  private weak var p2pSig: CallSignalClient?

  /// call:p2p from the peer (server forwards verbatim). Called by OLCallManager.onSignal. Main queue.
  public func onP2pSignal(_ d: [String: Any]) {
    let callId = (d["callId"] as? String) ?? ""
    guard let msg = d["msg"] as? [String: Any] else { return }
    if !p2pCallId.isEmpty && callId != p2pCallId { return }
    guard let c = p2pCfg else { if let o = msg["sdp"] as? String { pendingOffer = o }; return }
    if msg["restart"] as? Bool == true { if c.offerer && p2p != .off { backToServer(); p2pRestart(tellPeer: false) }; return }
    guard let sdp = msg["sdp"] as? String, !sdp.isEmpty else { return }
    if c.offerer { if p2p == .trying && ol_p2p_remote(sdp) != 0 { p2pFail("answer") }; return }
    backToServer(); pendingOffer = sdp; p2pBegin(c)
  }

  /// relay logins the server already mints (call:turnRefresh, server/calls/index.ts:334); prefer UDP over TCP
  private func p2pPrepare(_ sig: CallSignalClient, callId: String) {
    p2pSig = sig; p2pCallId = callId
    let offerer = (onIsCaller?(callId)) ?? false
    sig.request("call:turnRefresh", ["callId": callId], timeout: 5) { [weak self] r in
      guard let self, self.p2pCallId == callId, self.direct || self.leg?.callId == callId else { return }
      var best: P2pCfg?
      for s in (r["iceServers"] as? [[String: Any]]) ?? [] {
        let urls = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] } ?? [])
        for u in urls where u.hasPrefix("turn:") {
          var rest = String(u.dropFirst(5)); var tcp = false
          if let q = rest.range(of: "?transport=") { tcp = rest[q.upperBound...] == "tcp"; rest = String(rest[..<q.lowerBound]) }
          if best == nil || (!tcp && best!.tcp) { best = P2pCfg(offerer: offerer, turn: rest, user: (s["username"] as? String) ?? "", pass: (s["credential"] as? String) ?? "", tcp: tcp) }
        }
      }
      guard let c = best else { NSLog("[OLP2P] no TURN config"); if self.direct { self.finishDirect(false, "no relay config") }; return }
      self.p2pCfg = c
      if !c.offerer && self.pendingOffer == nil { self.p2p = .trying; self.armTimeout(); return }
      self.p2pBegin(c)
    }
  }
  /// set by OLCallManager: true when this phone placed the call (caller = ICE controlling, sends the offer)
  public var onIsCaller: ((String) -> Bool)?

  private static let evCb: ol_p2p_cb = { ev, text, _ in
    let t = text.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async { NativeCallMedia.shared.p2pEvent(Int(ev), t) }
  }
  private func p2pEvent(_ ev: Int, _ text: String) {
    guard p2p == .trying || p2p == .live else { return }
    if ev == 1 { sendP2p(["sdp": text, "offer": p2pCfg?.offerer == true]) }
    else if ev == 2 && direct { directUp() }
    else if ev == 3 { p2pFail(text) }
  }
  private func sendP2p(_ msg: [String: Any]) {
    guard !p2pCallId.isEmpty, let sig = p2pSig else { return }
    sig.request("call:p2p", ["callId": p2pCallId, "msg": msg], timeout: 5) { [weak self] r in if r["ok"] as? Bool != true { self?.p2pFail("send") } }
  }
  private func p2pBegin(_ c: P2pCfg) {
    PJSIPEngine.shared.start()
    var cfg = ol_p2p_cfg(); cfg.offerer = c.offerer ? 1 : 0; cfg.turn_tcp = c.tcp ? 1 : 0; cfg.relay_only = 0; cfg.test_tone_hz = 0
    let r: Int32 = c.turn.withCString { a in c.user.withCString { u in c.pass.withCString { p in
      cfg.stun = a; cfg.turn = a; cfg.turn_user = u; cfg.turn_pass = p   // ol_p2p_begin copies the strings
      return ol_p2p_begin(&cfg, Self.evCb, nil) } } }
    if r != 0 { return p2pFail("begin \(r)") }
    if direct { _ = ol_p2p_activate(1) } // the only path: wired to mic/speaker from the start
    p2p = .trying; if muted { _ = ol_p2p_set_mute(1) }
    if let o = pendingOffer { pendingOffer = nil; _ = ol_p2p_remote(o) }
    poll(armTimeout())
  }
  @discardableResult private func armTimeout() -> Int {
    gen += 1; let g = gen
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in if let self, g == self.gen, self.p2p == .trying { self.p2pFail("timeout") } }
    return g
  }
  private func poll(_ g: Int) {
    guard g == gen, p2p == .trying || p2p == .live else { return }
    var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0
    _ = ol_p2p_stats(&rx, &lost, &tx)
    if direct {
      if p2p == .live { if rx != lastRx { lastRx = rx; lastRxAt = Date() } else if Date().timeIntervalSince(lastRxAt) > 3 { return p2pRestart(tellPeer: true) } }
    } else if p2p == .trying && rx >= 10 && tx >= 10 { // connected = RTP flowing both ways on the direct leg
      _ = ol_p2p_activate(1); p2p = .live; lastRx = rx; lastRxAt = Date(); ol_sfu_stop() // drop only the server audio leg
    } else if p2p == .live {
      if rx != lastRx { lastRx = rx; lastRxAt = Date() }
      else if Date().timeIntervalSince(lastRxAt) > 3 { backToServer(); return p2pRestart(tellPeer: true) }
      if videoStarted && !videoP2p { var vr: UInt32 = 0, vt: UInt32 = 0; ol_p2p_video_stats(&vr, &vt)
        if vr >= 10 && vt >= 10 && ol_p2p_video_live(1) == 0 { videoP2p = true } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (p2p == .live ? 0.5 : 0.05)) { [weak self] in self?.poll(g) }
  }
  private func backToServer() {
    if direct { return } // no server route on a phone<->phone call
    if videoP2p { videoP2p = false; _ = ol_p2p_video_live(0) }
    if p2p == .live { _ = ol_p2p_activate(0); if let l = leg { startLeg(l); if muted { _ = ol_sfu_set_mute(1) } } }
  }
  private func p2pFail(_ why: String) {
    guard p2p != .off else { return }
    NSLog("[OLP2P] direct leg off (%@); server route", why)
    backToServer(); gen += 1; p2p = .failed; ol_p2p_stop()
    guard direct else { return }
    if directDone != nil { return finishDirect(false, why) } // first connect failed: CallKit/UI decide as before
    let g = gen // mid-call: keep retrying the same single path until the call ends
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if let self, g == self.gen, self.direct, self.p2p == .failed { self.p2pRestart(tellPeer: true) } }
  }

  // ---- Direct (phone<->phone) single path
  private var direct = false
  private var directDone: ((Bool, String?) -> Void)?
  private var directVideo = false
  private func connectDirect(_ sig: CallSignalClient, callId: String, video: Bool, done: @escaping (Bool, String?) -> Void) {
    if direct && p2pCallId == callId { done(true, nil); return }
    direct = true; directDone = done; directVideo = video
    PJSIPEngine.shared.start()
    p2pPrepare(sig, callId: callId)
    // ICE has its own 15 s timeout (armTimeout); this covers a stuck turnRefresh
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in if let self, self.directDone != nil, self.p2pCallId == callId { self.finishDirect(false, "timeout") } }
  }
  private func finishDirect(_ ok: Bool, _ err: String?) {
    guard let d = directDone else { return }
    directDone = nil
    if !ok { NSLog("[OLP2P] direct connect failed: %@", err ?? "?") }
    d(ok, ok ? nil : "direct: \(err ?? "failed")")
  }
  /// ICE connected (ol_p2p ev 2): the call's one path is up.
  private func directUp() {
    p2p = .live; _ = ol_p2p_activate(1)
    var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0; _ = ol_p2p_stats(&rx, &lost, &tx); lastRx = rx; lastRxAt = Date()
    PJSIPEngine.shared.ensureSound() // no-op until CallKit didActivate
    startDirectVideo(callId: p2pCallId, cameraOn: directVideo && directDone != nil) // receive side always ready
    if videoStarted { videoP2p = ol_p2p_video_live(1) == 0 }
    finishDirect(true, nil)
  }
  private func startDirectVideo(callId: String, cameraOn: Bool) {
    if !videoStarted {
      videoCallId = callId
      let r = OLCallVideo.shared.start(ip: "", port: 0, txKey: "", rxKey: "", ssrcs: [Self.rnd(5_000_000), Self.rnd(6_000_000), Self.rnd(7_000_000)], pt: 102)
      if r != 0 { NSLog("[OLMedia] direct video start failed: %d", r); return }
      videoStarted = true
      OLCallVideo.shared.onRemoteFirstFrame = { [weak self] in DispatchQueue.main.async { self?.remoteOn = true; self?.report() } }
      if p2p == .live { videoP2p = ol_p2p_video_live(1) == 0 }
    }
    if cameraOn { openCamera(tries: 20) }
  }
  private func p2pRestart(tellPeer: Bool) {
    guard let c = p2pCfg else { return }
    p2p = .trying
    if c.offerer { if ol_p2p_restart() != 0 { return p2pFail("restart") }; if direct { _ = ol_p2p_activate(1) }; poll(armTimeout()) }
    else { ol_p2p_stop(); armTimeout(); if tellPeer { sendP2p(["restart": true]) } }
  }
  private func p2pStopAll() {
    finishDirect(false, "ended"); direct = false
    videoP2p = false; gen += 1; p2p = .off; p2pCfg = nil; pendingOffer = nil; p2pCallId = ""; muted = false
    ol_p2p_stop()
  }
}
