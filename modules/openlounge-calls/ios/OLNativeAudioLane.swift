import AVFoundation
import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

/// b75 single path: Android → iPhone incoming AUDIO calls only. Native Swift owns one send + one recv
/// RTCPeerConnection built on the StreamWebRTC 125.6422.070 framework the app already ships (no libmediasoupclient,
/// no second WebRTC binary). mediasoup transport parameters (ICE-lite / DTLS) are translated into SDP here, in the
/// style of mediasoup-client's Unified Plan handler. Signaling stays on the page's authenticated realtime socket: every
/// ms:* request is relayed through JS (`onMsRequest` → page `__olNativeMsReq` → `msResponse`).
/// CallKit is the sole owner of audio: RTCAudioSession is in manual mode; the mic producer is built at once but the
/// audio unit stays off until provider(didActivate:) (OLCallManager → `callKitActivated()` / `laneEnsureAudio()`). No AVAudioSession category changes here.
final class OLNativeAudioLane: NSObject {
  static var shared: OLNativeAudioLane?
  /// Set by OLCallManager.didActivate / reset; the lane awaits it before producing media.
  private static var activated = false
  private static var activationWaiters: [CheckedContinuation<Void, Never>] = []

  static func callKitActivated() {
    DispatchQueue.main.async {
      activated = true
      let w = activationWaiters; activationWaiters.removeAll()
      w.forEach { $0.resume() }
    }
  }
  /// b78: a late didDeactivate from a previous call must not clear the flag for the live lane's call.
  static func callKitDeactivated() {
    DispatchQueue.main.async {
      if let l = shared, !l.closed { NSLog("[OLCalls] lane ignore didDeactivate (live lane %@)", l.callId); return }
      activated = false
    }
  }
  @MainActor static func waitForActivation(timeout: Double) async -> Bool {
    if activated { return true }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      activationWaiters.append(c)
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        let w = activationWaiters; activationWaiters.removeAll()
        w.forEach { $0.resume() }
      }
    }
    return activated
  }

  typealias Request = (_ event: String, _ data: [String: Any]) async throws -> [String: Any]
  typealias Emit = (_ detail: [String: Any]) -> Void

  let callId: String
  private let nativeConn: String
  private let iceServers: [[String: Any]]
  private let req: Request
  private let emit: Emit
  private(set) var connected = false
  private var closed = false
  private var muted = false
  private var t0 = Date()

  #if canImport(WebRTC)
  private static let factory: RTCPeerConnectionFactory = {
    RTCInitializeSSL()
    return RTCPeerConnectionFactory()
  }()
  private var sendPc: RTCPeerConnection?
  private var recvPc: RTCPeerConnection?
  private var micTrack: RTCAudioTrack?
  #endif
  private var routerCaps: [String: Any] = [:]
  private var sendT: [String: Any] = [:]
  private var recvT: [String: Any] = [:]
  private var recvConnected = false
  private var producerId: String?
  private var consumers: [[String: Any]] = []   // consumer descriptors, in m-section order
  private var resumed = Set<String>()
  private var syncing = false

  init(callId: String, nativeConn: String, iceServers: [[String: Any]], req: @escaping Request, emit: @escaping Emit) {
    self.callId = callId; self.nativeConn = nativeConn; self.iceServers = iceServers; self.req = req; self.emit = emit
  }

  // MARK: - logging (secrets-free: no ICE pwd, no fingerprints, no tokens)
  private func log(_ stage: String, _ extra: String = "") {
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    NSLog("[OLCalls] lane stage=%@ callId=%@ +%dms %@", stage, callId, ms, extra)
    emit(["state": "diag", "stage": stage, "ms": ms])
  }

  private func r(_ event: String, _ data: [String: Any] = [:]) async throws -> [String: Any] {
    var d = data; d["callId"] = callId; d["nativeConn"] = nativeConn
    let x = try await req(event, d)
    if (x["ok"] as? Bool) == false { throw NSError(domain: "OLLane", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(event) rejected"]) }
    return x
  }

  // MARK: - connect
  @MainActor func connect() async throws {
    t0 = Date()
    log("connect-start")
    let joined = try await r("ms:join")
    guard let caps = joined["routerRtpCapabilities"] as? [String: Any] else { throw err("Mediasoup admission failed") }
    routerCaps = caps
    log("joined")
    async let so = r("ms:transport:create", ["direction": "send"])
    async let ro = r("ms:transport:create", ["direction": "recv"])
    let (s, rr) = try await (so, ro)
    guard let st = s["transport"] as? [String: Any], let rt = rr["transport"] as? [String: Any] else { throw err("Mediasoup transport setup failed") }
    sendT = st; recvT = rt
    #if canImport(WebRTC)
    sendPc = makePc(); recvPc = makePc()
    #endif
    log("transports")
    try check()
    // Remote audio can be negotiated before CallKit activation: with manual audio the unit is off, nothing plays.
    Task { @MainActor in await self.syncConsumers() }
    // b78: never block the producer on didActivate (b77 calls 35961993 / 711a2969: 15 s wait, no ms:produce, "can't
    // connect"). Manual audio keeps the unit OFF, so the pre-warmed mic sends nothing until CallKit's didActivate
    // flips isAudioEnabled (OLCallManager) — CallKit stays the only thing that turns audio on.
    #if canImport(WebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    if !rtc.useManualAudio { rtc.useManualAudio = true; rtc.isAudioEnabled = false }
    #endif
    try await produceMic()
    try check()
    connected = true
    log("connected", Self.activated ? "activated=1" : "activated=0")
    emit(["state": "connected"])
    // session already live (didActivate came before the lane) → enable the unit now; otherwise didActivate does it
    OLCallManager.shared.laneEnsureAudio()
  }

  private func err(_ m: String) -> NSError { NSError(domain: "OLLane", code: 2, userInfo: [NSLocalizedDescriptionKey: m]) }
  private func check() throws { if closed { throw err("native media closed") } }

  #if canImport(WebRTC)
  private func makePc() -> RTCPeerConnection? {
    let cfg = RTCConfiguration()
    cfg.sdpSemantics = .unifiedPlan
    cfg.bundlePolicy = .maxBundle
    cfg.rtcpMuxPolicy = .require
    cfg.iceTransportPolicy = .all
    cfg.continualGatheringPolicy = .gatherContinually
    cfg.iceServers = iceServers.compactMap { s in
      let urls: [String] = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] } ?? [])
      guard !urls.isEmpty else { return nil }
      return RTCIceServer(urlStrings: urls, username: s["username"] as? String, credential: s["credential"] as? String)
    }
    let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
    return Self.factory.peerConnection(with: cfg, constraints: c, delegate: self)
  }
  #endif

  // MARK: - router capability helpers
  private var routerOpusPt: Int {
    let codecs = routerCaps["codecs"] as? [[String: Any]] ?? []
    let o = codecs.first { ($0["mimeType"] as? String)?.lowercased() == "audio/opus" }
    return (o?["preferredPayloadType"] as? Int) ?? 100
  }
  static let audioExtUris: Set<String> = [
    "urn:ietf:params:rtp-hdrext:sdes:mid",
    "urn:ietf:params:rtp-hdrext:ssrc-audio-level",
    "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
  ]
  private var routerAudioExts: [[String: Any]] {
    (routerCaps["headerExtensions"] as? [[String: Any]] ?? []).filter {
      ($0["kind"] as? String) == "audio" && Self.audioExtUris.contains(($0["uri"] as? String) ?? "")
    }
  }
  /// Device rtpCapabilities sent with ms:consume (Opus-only, audio extensions the router offers).
  var rtpCapabilities: [String: Any] {
    ["codecs": [["kind": "audio", "mimeType": "audio/opus", "preferredPayloadType": routerOpusPt, "clockRate": 48000,
                 "channels": 2, "parameters": [String: Any](), "rtcpFeedback": [["type": "transport-cc", "parameter": ""]]]],
     "headerExtensions": routerAudioExts.map { ["kind": "audio", "uri": $0["uri"] ?? "", "preferredId": $0["preferredId"] ?? 1,
                                                "preferredEncrypt": false, "direction": "sendrecv"] }]
  }

  // MARK: - send (Opus 48k mic)
  @MainActor private func produceMic() async throws {
    #if canImport(WebRTC)
    guard let pc = sendPc else { throw err("no send pc") }
    let src = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
    let track = Self.factory.audioTrack(with: src, trackId: "ol-mic-\(callId.prefix(8))")
    track.isEnabled = !muted
    micTrack = track
    let ti = RTCRtpTransceiverInit()
    ti.direction = .sendOnly
    ti.streamIds = ["ol-\(callId.prefix(8))"]
    guard let tr = pc.addTransceiver(with: track, init: ti) else { throw err("addTransceiver failed") }
    let offer = try await pc.olOffer()
    try await pc.olSetLocal(offer)
    let local = OLSdp.parseLocalAudio(offer.sdp)
    guard let pt = local.opusPt, let ssrc = local.ssrc else { throw err("local offer missing opus/ssrc") }
    let mid = local.mid ?? tr.mid
    let exts = local.extmaps.filter { e in routerAudioExts.contains { ($0["uri"] as? String) == e.uri } }
    let answer = OLSdp.remote(transport: sendT, sections: [.init(mid: mid, pt: pt, fmtp: "minptime=10;useinbandfec=1;stereo=0;sprop-stereo=0;usedtx=0",
                                                                extmaps: exts, direction: "recvonly", ssrc: nil, cname: nil)],
                              setup: "passive")
    try await pc.olSetRemote(RTCSessionDescription(type: .answer, sdp: answer))
    // DTLS: local role is client (offer actpass → remote answer passive), same as mediasoup-client.
    guard let fp = OLSdp.fingerprint(pc.localDescription?.sdp ?? offer.sdp) else { throw err("no local fingerprint") }
    _ = try await r("ms:transport:connect", ["direction": "send", "transportId": sendT["id"] ?? "",
                                              "dtlsParameters": ["role": "client", "fingerprints": [["algorithm": fp.0, "value": fp.1]]]])
    log("send-dtls")
    if let sender = tr.sender as RTCRtpSender? {
      let p = sender.parameters
      for e in p.encodings { e.maxBitrateBps = 64_000; e.networkPriority = .high; e.bitratePriority = 4 }
      sender.parameters = p
    }
    let rtp: [String: Any] = [
      "mid": mid,
      "codecs": [["mimeType": "audio/opus", "payloadType": pt, "clockRate": 48000, "channels": 2,
                  "parameters": ["minptime": 10, "useinbandfec": 1, "sprop-stereo": 0, "usedtx": 0],
                  "rtcpFeedback": [["type": "transport-cc", "parameter": ""]]]],
      "headerExtensions": exts.map { ["uri": $0.uri, "id": $0.id, "encrypt": false, "parameters": [String: Any]()] },
      "encodings": [["ssrc": ssrc, "dtx": false, "maxBitrate": 64000]],
      "rtcp": ["cname": local.cname ?? "ol", "reducedSize": true],
    ]
    let x = try await r("ms:produce", ["transportId": sendT["id"] ?? "", "kind": "audio", "rtpParameters": rtp,
                                       "appData": ["source": "mic", "native": true, "lane": "swift"]])
    producerId = x["id"] as? String
    log("produced", "opusPt=\(pt)")
    #endif
  }

  // MARK: - recv
  @MainActor func syncConsumers() async {
    if closed || syncing { return }
    syncing = true; defer { syncing = false }
    do {
      let x = try await r("ms:consume", ["transportId": recvT["id"] ?? "", "rtpCapabilities": rtpCapabilities])
      let known = Set(consumers.compactMap { $0["id"] as? String })
      let mine = producerId
      let got = (x["consumers"] as? [[String: Any]] ?? []).filter { p in
        (p["kind"] as? String) == "audio" && (p["producerId"] as? String) != mine
          && !known.contains((p["id"] as? String) ?? "")
      }
      if !got.isEmpty {
        consumers.append(contentsOf: got)
        try await negotiateRecv()
      }
      for c in consumers {
        guard let id = c["id"] as? String, !resumed.contains(id) else { continue }
        if (try? await r("ms:consumer:resume", ["consumerId": id])) != nil { resumed.insert(id) }
      }
      if !got.isEmpty { log("consumed", "n=\(got.count)"); emit(["state": "remote-audio", "on": true]) }
    } catch { log("consume-failed", "LOUD=1") }
  }

  @MainActor private func negotiateRecv() async throws {
    #if canImport(WebRTC)
    guard let pc = recvPc else { return }
    let sections: [OLSdp.Section] = consumers.enumerated().map { i, c in
      let rp = c["rtpParameters"] as? [String: Any] ?? [:]
      let codec = (rp["codecs"] as? [[String: Any]])?.first ?? [:]
      let params = codec["parameters"] as? [String: Any] ?? [:]
      let fmtp = params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";")
      let exts = (rp["headerExtensions"] as? [[String: Any]] ?? []).compactMap { e -> OLSdp.Ext? in
        guard let u = e["uri"] as? String, let id = e["id"] as? Int else { return nil }
        return .init(id: id, uri: u)
      }
      let enc = (rp["encodings"] as? [[String: Any]])?.first ?? [:]
      let cname = (rp["rtcp"] as? [String: Any])?["cname"] as? String
      return .init(mid: (rp["mid"] as? String) ?? "r\(i)", pt: (codec["payloadType"] as? Int) ?? routerOpusPt,
                   fmtp: fmtp.isEmpty ? "minptime=10;useinbandfec=1" : fmtp, extmaps: exts, direction: "sendonly",
                   ssrc: (enc["ssrc"] as? NSNumber)?.uint32Value, cname: cname ?? "ol-remote")
    }
    let offer = OLSdp.remote(transport: recvT, sections: sections, setup: "actpass")
    try await pc.olSetRemote(RTCSessionDescription(type: .offer, sdp: offer))
    let answer = try await pc.olAnswer()
    try await pc.olSetLocal(answer)
    if !recvConnected {
      guard let fp = OLSdp.fingerprint(answer.sdp) else { throw err("no local fingerprint") }
      _ = try await r("ms:transport:connect", ["direction": "recv", "transportId": recvT["id"] ?? "",
                                                "dtlsParameters": ["role": "client", "fingerprints": [["algorithm": fp.0, "value": fp.1]]]])
      recvConnected = true
      log("recv-dtls")
    }
    #endif
  }

  // MARK: - controls
  func setMuted(_ m: Bool) {
    muted = m
    #if canImport(WebRTC)
    micTrack?.isEnabled = !m
    #endif
  }

  func close() {
    if closed { return }
    closed = true
    log("close")
    #if canImport(WebRTC)
    sendPc?.close(); recvPc?.close(); sendPc = nil; recvPc = nil; micTrack = nil
    #endif
    Task { _ = try? await self.req("ms:leave", ["callId": callId, "nativeConn": nativeConn]) }
    if Self.shared === self { Self.shared = nil }
  }
}

#if canImport(WebRTC)
extension OLNativeAudioLane: RTCPeerConnectionDelegate {
  func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) {}
  func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
  func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
  func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) {} // ICE-lite SFU: no trickle needed
  func peerConnection(_ pc: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
  func peerConnection(_ pc: RTCPeerConnection, didOpen d: RTCDataChannel) {}
  func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceConnectionState) {
    let dir = pc === sendPc ? "send" : "recv"
    NSLog("[OLCalls] lane ice %@=%ld callId=%@", dir, s.rawValue, callId)
    if s == .failed || s == .disconnected { emit(["state": s == .failed ? "failed" : "disconnected", "dir": dir]) }
    if s == .connected, connected { emit(["state": "connected"]) }
  }
}

extension RTCPeerConnection {
  private static var audioOnly: RTCMediaConstraints {
    RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)
  }
  func olOffer() async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { c in
      offer(for: Self.audioOnly) { d, e in if let d = d { c.resume(returning: d) } else { c.resume(throwing: e ?? NSError(domain: "OLLane", code: 3)) } }
    }
  }
  func olAnswer() async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { c in
      answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { d, e in
        if let d = d { c.resume(returning: d) } else { c.resume(throwing: e ?? NSError(domain: "OLLane", code: 4)) }
      }
    }
  }
  func olSetLocal(_ d: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      setLocalDescription(d) { e in if let e = e { c.resume(throwing: e) } else { c.resume() } }
    }
  }
  func olSetRemote(_ d: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      setRemoteDescription(d) { e in if let e = e { c.resume(throwing: e) } else { c.resume() } }
    }
  }
}
#endif

/// mediasoup transport params → SDP (mediasoup-client RemoteSdp equivalent, audio-only, BUNDLE, ICE-lite).
enum OLSdp {
  struct Ext { let id: Int; let uri: String }
  struct Section { let mid: String; let pt: Int; let fmtp: String; let extmaps: [Ext]; let direction: String; let ssrc: UInt32?; let cname: String? }
  struct LocalAudio { var mid: String?; var opusPt: Int?; var ssrc: UInt32?; var cname: String?; var extmaps: [Ext] = [] }

  static func parseLocalAudio(_ sdp: String) -> LocalAudio {
    var a = LocalAudio()
    for raw in sdp.components(separatedBy: "\n") {
      let l = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if l.hasPrefix("a=mid:"), a.mid == nil { a.mid = String(l.dropFirst(6)) }
      else if l.hasPrefix("a=rtpmap:"), l.lowercased().contains(" opus/48000"), a.opusPt == nil {
        a.opusPt = Int(l.dropFirst(9).split(separator: " ").first ?? "")
      } else if l.hasPrefix("a=extmap:") {
        let p = l.dropFirst(9).split(separator: " ")
        if p.count >= 2, let id = Int(p[0].split(separator: "/")[0]) { a.extmaps.append(.init(id: id, uri: String(p[1]))) }
      } else if l.hasPrefix("a=ssrc:"), a.ssrc == nil || a.cname == nil {
        let p = l.dropFirst(7).split(separator: " ", maxSplits: 1)
        if a.ssrc == nil { a.ssrc = UInt32(p[0]) }
        if p.count == 2, p[1].hasPrefix("cname:") { a.cname = String(p[1].dropFirst(6)) }
      }
    }
    return a
  }

  static func fingerprint(_ sdp: String) -> (String, String)? {
    for raw in sdp.components(separatedBy: "\n") {
      let l = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if l.hasPrefix("a=fingerprint:") {
        let p = l.dropFirst(14).split(separator: " ")
        if p.count == 2 { return (String(p[0]).lowercased(), String(p[1])) }
      }
    }
    return nil
  }

  static func remote(transport t: [String: Any], sections: [Section], setup: String) -> String {
    let ice = t["iceParameters"] as? [String: Any] ?? [:]
    let dtls = t["dtlsParameters"] as? [String: Any] ?? [:]
    let fps = dtls["fingerprints"] as? [[String: Any]] ?? []
    let fp = fps.first { ($0["algorithm"] as? String) == "sha-256" } ?? fps.last ?? [:]
    let cands = t["iceCandidates"] as? [[String: Any]] ?? []
    var s = ["v=0", "o=mediasoup-client 10000 1 IN IP4 0.0.0.0", "s=-", "t=0 0", "a=ice-lite",
             "a=fingerprint:\(fp["algorithm"] ?? "sha-256") \(fp["value"] ?? "")",
             "a=msid-semantic: WMS *", "a=group:BUNDLE " + sections.map(\.mid).joined(separator: " ")]
    for (i, m) in sections.enumerated() {
      s.append("m=audio 7 UDP/TLS/RTP/SAVPF \(m.pt)")
      s.append("c=IN IP4 127.0.0.1")
      s.append("a=rtpmap:\(m.pt) opus/48000/2")
      s.append("a=fmtp:\(m.pt) \(m.fmtp)")
      s.append("a=rtcp-fb:\(m.pt) transport-cc")
      for e in m.extmaps { s.append("a=extmap:\(e.id) \(e.uri)") }
      s.append("a=setup:\(setup)")
      s.append("a=mid:\(m.mid)")
      s.append("a=\(m.direction)")
      s.append("a=ice-ufrag:\(ice["usernameFragment"] ?? "")")
      s.append("a=ice-pwd:\(ice["password"] ?? "")")
      do {
        for c in cands {
          let proto = ((c["protocol"] as? String) ?? "udp").lowercased()
          var line = "a=candidate:\(c["foundation"] ?? "0") 1 \(proto) \(c["priority"] ?? 0) \(c["address"] ?? c["ip"] ?? "") \(c["port"] ?? 0) typ \(c["type"] ?? "host")"
          if proto == "tcp" { line += " tcptype \(c["tcpType"] ?? "passive")" }
          s.append(line)
        }
        s.append("a=end-of-candidates")
      }
      s.append("a=ice-options:renomination")
      s.append("a=rtcp-mux")
      s.append("a=rtcp-rsize")
      if let ssrc = m.ssrc {
        let msid = "ol-remote-\(i)"
        s.append("a=msid:\(msid) \(msid)-audio")
        s.append("a=ssrc:\(ssrc) cname:\(m.cname ?? "ol-remote")")
      }
    }
    return s.joined(separator: "\r\n") + "\r\n"
  }
}
