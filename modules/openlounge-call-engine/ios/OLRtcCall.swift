// OLRtcCall — the iOS P2P call media path per /workspace/builds/signal-rebuild-rtc-contract.md (v1).
// One RTCPeerConnection per call over the existing OL socket (rtc:signal / rtc:iceConfig). Replaced
// the old SIP/SFU legs as the call media path. Audio comes ONLY from OLCallAudioEngine.localAudioTrack, which exists only after
// CallKit didActivate → OLAudioSessionOwner → engine (activation before media).
// Failure taxonomy: local (permission/device/session/codec/webrtc-not-linked) → report, never ICE restart / relay.
// signaling (server error codes) → report, never ICE restart. network (ICE failed / disconnected 2.5 s) → ICE restart
// with backoff 0/1/2/4/8 s, give up after 45 s; first-connect ICE failed → network failure.
import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

public enum OLRtcFailure: Error, CustomStringConvertible {
  case local(String), signaling(String), network(String), ended
  public var description: String {
    switch self { case .local(let s): return "local:\(s)"; case .signaling(let s): return "signaling:\(s)"; case .network(let s): return "network:\(s)"; case .ended: return "ended" }
  }
}

public final class OLRtcCall: NSObject {
  public static let shared = OLRtcCall()
  public static let signalCodes: Set<String> = ["bad_request", "too_large", "rate_limited", "unknown_call", "not_participant", "not_active", "stale_generation", "replayed"]

  private weak var sig: CallSignalClient?
  /// RingRTC session model: all rtc:signal traffic is E2E-sealed (OLX3DH-v1) and relayed as rc:msg.
  private var rc: OLRcSealedTransport?
  private var callId: String?
  private var isCaller = false
  private var gen = 0
  private var seq = 0
  private var remoteGen = 0
  private var done: ((Result<Void, OLRtcFailure>) -> Void)?
  private var everConnected = false
  private var restartStarted: Date?
  private var restartAttempt = 0
  private var discoTimer: Timer?
  /// Called once per call when media is connected (first ICE connected) and on later terminal failure.
  public var onTerminal: ((OLRtcFailure) -> Void)?

  #if canImport(WebRTC)
  private var pc: RTCPeerConnection?
  private var pendingRemote: [RTCIceCandidate] = []
  private var currentOffer: RTCSessionDescription?
  private var offerInFlight = false
  private var answerInFlight = false
  private var pendingSignals: [[String: Any]] = []
  #endif

  public static var isLinked: Bool {
    #if canImport(WebRTC)
    return true
    #else
    return false
    #endif
  }

  /// Start media for an ACTIVE call. Precondition: OLCallAudioEngine is running (activation already completed).
  public func start(_ sig: CallSignalClient, callId: String, isCaller: Bool, video: Bool = false, done: @escaping (Result<Void, OLRtcFailure>) -> Void) {
    precondition(Thread.isMainThread)
    close(sendBye: false)
    self.sig = sig; self.callId = callId; self.isCaller = isCaller
    gen = 0; seq = 0; remoteGen = 0; everConnected = false; restartAttempt = 0; restartStarted = nil
    self.done = done
    let t = OLRcSealedTransport(sig, callId: callId, isCaller: isCaller)
    t.onSignal = { [weak self] d in self?.onSignal(d) }
    rc = t
    OLRcCallManager.shared.begin(callId, outgoing: isCaller)
    OLRcCallManager.shared.connecting(callId)
    #if canImport(WebRTC)
    guard OLCallAudioEngine.shared.isRunning, let track = OLCallAudioEngine.shared.localAudioTrack else {
      return finish(.failure(.local("audio engine not running")))
    }
    fetchIce { [weak self] cfg in
      guard let self, self.callId == callId else { return }
      guard let cfg else { return self.finish(.failure(.signaling("iceConfig"))) }
      let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      guard let pc = OLCallAudioEngine.shared.factory.peerConnection(with: cfg, constraints: c, delegate: self) else {
        return self.finish(.failure(.local("peerConnection create failed")))
      }
      self.pc = pc
      pc.add(track, streamIds: ["ol"])
      // Always negotiate a video slot, including calls that start audio-only. The callee adopts the
      // offered transceiver after setRemote rather than creating a second video m-line.
      OLRtcVideo.shared.callId = callId
      if isCaller { pc.add(OLRtcVideo.shared.makeTrack(OLCallAudioEngine.shared.factory), streamIds: ["ol"]) }
      let queued = self.pendingSignals; self.pendingSignals = []
      queued.forEach { self.onSignal($0) }
      OLCallDiskLog.shared.mark("rtc", "pc-created caller=\(isCaller)")
      if isCaller { self.makeOffer(restart: false) } else { self.send("ready") }
    }
    #else
    // Linux / no WebRTC.xcframework: typed LOCAL failure. Never falls back to TURN/PJSIP/relay.
    finish(.failure(.local("webrtc_not_linked")))
    #endif
  }

  // MARK: socket
  private func send(_ kind: String, extra: [String: Any] = [:]) {
    guard let rc, let callId else { return }
    var d: [String: Any] = ["callId": callId, "gen": gen, "seq": seq, "kind": kind]
    seq += 1
    extra.forEach { d[$0] = $1 }
    rc.send(d) { [weak self] r in DispatchQueue.main.async {
      guard r["ok"] as? Bool != true else { return }
      let code = (r["error"] as? String) ?? "unknown"
      if code == "replayed" || code == "stale_generation" { return } // benign
      if kind == "bye" { return }
      OLCallDiskLog.shared.mark("rtc", "signal-error \(kind) \(code)")
      if code == "not_active" && kind == "offer" { return } // callee 'ready' triggers re-offer
      self?.terminal(.signaling(code))
    } }
  }

  /// OLCallManager forwards server evt "rc:msg" here (sealed; opened by this call's OLX3DH-v1 session).
  public func onRcMsg(_ m: [String: Any]) { precondition(Thread.isMainThread); rc?.onRcMsg(m) }

  /// Opened rtc:signal payloads (from OLRcSealedTransport). Plain server "rtc:signal" is no longer accepted.
  public func onSignal(_ d: [String: Any]) {
    precondition(Thread.isMainThread)
    guard let id = d["callId"] as? String, id == callId, let kind = d["kind"] as? String else { return }
    #if canImport(WebRTC)
    guard pc != nil else { if pendingSignals.count < 256 { pendingSignals.append(d) }; return }
    #endif
    let g = (d["gen"] as? NSNumber)?.intValue ?? 0
    if g < remoteGen { return }
    remoteGen = g
    #if canImport(WebRTC)
    switch kind {
    case "ready": if isCaller { if let o = currentOffer { send("offer", extra: ["sdp": o.sdp]) } else { makeOffer(restart: false) } }
    case "offer": if !isCaller, let sdp = d["sdp"] as? String { if g > gen { gen = g; seq = 0 }; acceptOffer(sdp) }
    case "answer":
      if isCaller, pc?.signalingState == .haveLocalOffer, let sdp = d["sdp"] as? String {
        pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] e in
          DispatchQueue.main.async { if let e { self?.terminal(.local("setRemote answer \(e.localizedDescription)")) } else { self?.flushCandidates() } }
        }
      }
    case "candidate":
      guard let c = d["candidate"] as? [String: Any], let s = c["candidate"] as? String else { return } // null = end
      let cand = RTCIceCandidate(sdp: s, sdpMLineIndex: Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0), sdpMid: c["sdpMid"] as? String)
      if pc?.remoteDescription == nil { pendingRemote.append(cand) } else { pc?.add(cand) { _ in } }
    case "restart": if isCaller { iceRestart() }
    case "bye": terminal(.ended)
    default: break
    }
    #endif
  }

  #if canImport(WebRTC)
  private func fetchIce(_ cb: @escaping (RTCConfiguration?) -> Void) {
    guard let sig, let callId else { return cb(nil) }
    sig.request("rtc:iceConfig", ["callId": callId]) { r in
      DispatchQueue.main.async {
        guard r["ok"] as? Bool == true, let cfg = r["config"] as? [String: Any] else { return cb(nil) }
        let rc = RTCConfiguration()
        rc.iceServers = ((cfg["iceServers"] as? [[String: Any]]) ?? []).compactMap { s in
          let urls = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] } ?? [])
          guard !urls.isEmpty else { return nil }
          return RTCIceServer(urlStrings: urls, username: s["username"] as? String, credential: s["credential"] as? String)
        }
        rc.iceTransportPolicy = .all
        rc.bundlePolicy = .maxBundle
        rc.rtcpMuxPolicy = .require
        rc.sdpSemantics = .unifiedPlan
        rc.continualGatheringPolicy = .gatherContinually
        cb(rc)
      }
    }
  }

  private func makeOffer(restart: Bool) {
    guard let pc, !offerInFlight else { return }; offerInFlight = true
    let c = RTCMediaConstraints(mandatoryConstraints: restart ? ["IceRestart": "true"] : nil, optionalConstraints: nil)
    pc.offer(for: c) { [weak self] sdp, e in
      DispatchQueue.main.async {
        guard let self, self.pc === pc else { return }
        guard let sdp else { self.offerInFlight = false; self.terminal(.local("offer \(e?.localizedDescription ?? "?")")); return }
        pc.setLocalDescription(sdp) { e in
          DispatchQueue.main.async {
            guard self.pc === pc else { return }
            self.offerInFlight = false
            if let e { self.terminal(.local("setLocal offer \(e.localizedDescription)")); return }
            self.currentOffer = sdp
            self.send("offer", extra: ["sdp": sdp.sdp])
          }
        }
      }
    }
  }

  private func acceptOffer(_ sdp: String) {
    guard let pc, !answerInFlight else { return }
    if pc.remoteDescription?.sdp == sdp, pc.signalingState == .stable, let answer = pc.localDescription, answer.type == .answer {
      send("answer", extra: ["sdp": answer.sdp]); return
    }
    answerInFlight = true
    pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] e in
      DispatchQueue.main.async {
        guard let self, self.pc === pc else { return }
        if let e { return self.terminal(.local("setRemote offer \(e.localizedDescription)")) }
        if let tx = pc.transceivers.first(where: { $0.mediaType == .video }) {
          var directionError: NSError?
          tx.setDirection(.sendRecv, error: &directionError)
          if let directionError { return self.terminal(.local("video direction \(directionError.domain):\(directionError.code) \(directionError.localizedDescription)")) }
          tx.sender.track = OLRtcVideo.shared.makeTrack(OLCallAudioEngine.shared.factory)
        }
        self.flushCandidates()
        pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { a, e in
          DispatchQueue.main.async {
            guard self.pc === pc else { return }
            guard let a else { return self.terminal(.local("answer \(e?.localizedDescription ?? "?")")) }
            pc.setLocalDescription(a) { e in
              DispatchQueue.main.async { guard self.pc === pc else { return }; if let e { self.terminal(.local("setLocal answer \(e.localizedDescription)")) } else { self.answerInFlight = false; self.send("answer", extra: ["sdp": a.sdp]) } }
            }
          }
        }
      }
    }
  }

  private func flushCandidates() { let p = pendingRemote; pendingRemote = []; p.forEach { pc?.add($0) { _ in } } }

  /// Network-only recovery. Caller: fresh creds → setConfiguration → gen++ → iceRestart offer. Callee: ask via 'restart'.
  private func iceRestart() {
    if restartStarted == nil { restartStarted = Date() }
    if Date().timeIntervalSince(restartStarted!) > 45 { return terminal(.network("ice restart gave up after 45s")) }
    let delays: [Double] = [0, 1, 2, 4, 8]
    let delay = delays[min(restartAttempt, delays.count - 1)]; restartAttempt += 1
    let id = callId
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.callId == id, self.pc != nil else { return }
      self.gen += 1; self.seq = 0
      if !self.isCaller { self.send("restart"); return }
      self.fetchIce { cfg in
        guard self.callId == id else { return }
        if let cfg { _ = self.pc?.setConfiguration(cfg) }
        self.makeOffer(restart: true)
      }
    }
  }
  #endif

  private func finish(_ r: Result<Void, OLRtcFailure>) {
    if let id = callId {
      switch r {
      case .success: OLRcCallManager.shared.connected(id)
      case .failure(let f): OLRcCallManager.shared.end(id, .failed, Self.rcEvent(f))
      }
    }
    let d = done; done = nil; d?(r)
  }
  private static func rcEvent(_ f: OLRtcFailure) -> OLRcCallEvent {
    let s = "\(f)"
    return s.hasPrefix("network") ? .endedConnectionFailure : s.hasPrefix("signaling") ? .endedSignalingFailure : s.hasPrefix("ended") ? .remoteHangup : .endedDeviceFailure
  }

  private func terminal(_ f: OLRtcFailure) {
    OLCallDiskLog.shared.mark("rtc", "terminal \(f)")
    if done != nil { finish(.failure(f)) } else { if let id = callId { OLRcCallManager.shared.end(id, "\(f)".hasPrefix("ended") ? .normal : .failed, Self.rcEvent(f)) }; onTerminal?(f) }
    close(sendBye: false)
  }

  public func setMute(_ m: Bool) { OLCallAudioEngine.shared.setMute(m) }

  public func close(sendBye: Bool) {
    if sendBye, callId != nil { send("bye") }
    discoTimer?.invalidate(); discoTimer = nil
    #if canImport(WebRTC)
    pc?.close(); pc = nil; pendingRemote = []; currentOffer = nil; offerInFlight = false; answerInFlight = false; pendingSignals = []
    #endif
    if let id = callId { OLRcCallManager.shared.end(id, .normal, .localHangup) }
    rc?.close(); rc = nil
    OLRtcVideo.shared.end()
    callId = nil; done = nil
  }
}

#if canImport(WebRTC)
extension OLRtcCall: RTCPeerConnectionDelegate {
  public func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) {
    DispatchQueue.main.async { self.send("candidate", extra: ["candidate": ["candidate": c.sdp, "sdpMid": c.sdpMid as Any, "sdpMLineIndex": c.sdpMLineIndex]]) }
  }
  public func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceConnectionState) {
    DispatchQueue.main.async {
      guard pc === self.pc else { return }
      OLCallDiskLog.shared.mark("rtc", "ice \(s.rawValue)")
      switch s {
      case .connected, .completed:
        self.discoTimer?.invalidate(); self.restartStarted = nil; self.restartAttempt = 0
        if !self.everConnected { self.everConnected = true; self.finish(.success(())) }
      case .disconnected:
        self.discoTimer?.invalidate()
        self.discoTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.iceRestart() }
      case .failed:
        if !self.everConnected { self.terminal(.network("first-connect ICE failed")) } else { self.iceRestart() }
      default: break
      }
    }
  }
  public func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) {}
  public func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  public func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  public func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
  public func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
  public func peerConnection(_ pc: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
  public func peerConnection(_ pc: RTCPeerConnection, didOpen dc: RTCDataChannel) {}
  public func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
    guard let v = rtpReceiver.track as? RTCVideoTrack else { return }
    DispatchQueue.main.async { if pc === self.pc { OLRtcVideo.shared.setRemote(v) } }
  }
}
#endif
