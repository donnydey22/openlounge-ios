import AVFoundation
import CallKit
import OpenLoungeCallEngine
import Foundation
import PushKit
import Security
import UIKit

// Native call ringing for Open Lounge (NATIVE_SPEC.md §3).
//
//   VoIP push (PushKit) ─▶ report a CallKit incoming call IMMEDIATELY (iOS kills/throttles apps that don't)
//   b104: every call is native. The app's own socket (CallSignalClient) carries call:start/ack/accept/decline/hangup
//   and the ms:* media setup (NativeCallMedia); the WebView is not in any call (bridge.ts call shim).
//   Telegram: CXAnswer -> answerCall -> callSessionManager.accept (tgios CallKitIntegration.swift:365-373,
//   PresentationCall.swift:1453-1527 accept at :1495/:1518); CXEnd -> endCall -> hangUp -> drop + context stop
//   (CallKitIntegration.swift:376-398, PresentationCall.swift:1530-1544); CXStart fulfils once the call is placed
//   (CallKitIntegration.swift:337-363); mute -> setIsMuted on the engine (:400-409, PresentationCall.swift:1562-1573).
//   CallKit Answer      ─▶ (b103 and before) JS opened https://openlounge.app/call/<id>?accept=1 in the WebView
//   CallKit Decline     ─▶ POST /api/calls/<id>/decline natively (works with the WebView not loaded). Build 19: with
//                          the push's per-call decline token (X-Call-Decline-Token: call+callee scoped, expires with
//                          the ring, single-use), so Decline works even when the 1-hour session has expired.
//   CallKit End/Mute    ─▶ JS injects openlounge:native-call {call:hangup | call:mute}
//   page call:*         ─▶ mirror into CallKit (outgoing call, connected, ended, muted) + audio route
//
// Audio: while a call is up the app's AVAudioSession is playAndRecord + voiceChat (Linphone; video too) with
// defaultToSpeaker + Bluetooth, so ringback and the call never land on the earpiece unexpectedly;
// the previous category is restored afterwards. All state lives on the main queue.

final class OLCall {
  let callId: String
  let uuid: UUID
  let incoming: Bool
  var video: Bool
  /// True only for an explicitly server-granted outgoing iPhone native-video call.
  let nativeMedia: Bool
  var answered = false
  var answeredInPage = false
  var name = "Open Lounge"
  var photo: String?
  /// b104: this call was placed/accepted by the app's own socket (native signaling)
  var native = false
  /// the other side's platform from the server's call info (callerPlatform / calleePlatform): ios|android|web
  var peerPlatform: String?
  var connected = false
  var ended = false
  var expiresAt: Date?
  var declineToken: String?
  var expiryTimer: Timer?
  var pollTimer: Timer?

  init(callId: String, uuid: UUID, incoming: Bool, video: Bool, nativeMedia: Bool = false) {
    self.callId = callId
    self.uuid = uuid
    self.incoming = incoming
    self.video = video
    self.nativeMedia = nativeMedia
  }
}

enum OLCallAuth {
  private static let service = "com.donnydey.openlounge.calls"
  private static let account = "access"

  private static func baseQuery() -> [String: Any] {
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  static func save(token: String, expMs: Double) {
    SecItemDelete(baseQuery() as CFDictionary)
    guard !token.isEmpty, token.count < 8192, expMs > 0,
          let data = try? JSONSerialization.data(withJSONObject: ["t": token, "exp": expMs]) else { return }
    var add = baseQuery()
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }

  /// A token that is still valid for at least 10 s, or nil.
  static func fresh() -> String? {
    var q = baseQuery()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = obj["t"] as? String, let exp = (obj["exp"] as? NSNumber)?.doubleValue else { return nil }
    return exp > Date().timeIntervalSince1970 * 1000 + 10_000 ? t : nil
  }
}

public final class OLCallManager: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
  public static let shared = OLCallManager()
  #if targetEnvironment(simulator)
  // Simulator CI only: SIMCTL_CHILD_OL_SIM_API_BASE=http://127.0.0.1:8787 points native calls at the CI decline server.
  private static var base: URL {
    if let s = ProcessInfo.processInfo.environment["OL_SIM_API_BASE"], s.hasPrefix("http://127.0.0.1:"), let u = URL(string: s) { return u }
    return URL(string: "https://openlounge.app")!
  }
  #else
  // Staging test builds set OLBaseURL (app.config.ts, OL_START_URL); production builds don't → https://openlounge.app
  private static let base: URL = {
    if let s = Bundle.main.object(forInfoDictionaryKey: "OLBaseURL") as? String, let u = URL(string: s), u.scheme == "https",
       let h = u.host, h == "openlounge.app" || h.hasSuffix(".up.railway.app") { return u }
    return URL(string: "https://openlounge.app")!
  }()
  #endif
  private static let idPattern = "^[A-Za-z0-9_-]{1,64}$"
  private static let declineTokenPattern = "^v1\\.[A-Za-z0-9_-]{8,500}\\.[A-Za-z0-9_-]{20,100}$"

  private var started = false
  /// b104: the app's own signaling socket (wss://openlounge.app/ws), signed in with the Keychain access token
  private(set) lazy var signal: CallSignalClient = {
    let c = CallSignalClient(baseURL: Self.base)
    c.tokenProvider = { OLCallAuth.fresh() }
    c.onEvent = { [weak self] ev, d in self?.onSignal(ev, d) }
    c.onAuthed = { [weak self, weak c] up in
      guard up else { return }
      if let c { OLRcSealedTransport.publish(c) } // OLX3DH-v1 bundle for this device
      self?.rebindLiveCalls()
    }
    return c
  }()
  private var registry: PKPushRegistry?
  private var provider: CXProvider?
  private let controller = CXCallController()
  private var calls: [UUID: OLCall] = [:]

  // shared with the JS thread
  private let lock = NSLock()
  private var token = ""
  private var pending: [[String: Any]] = []
  private var jsReady = false
  private weak var module: OpenLoungeCallsModule?

  // audio — sole path via OLAudioSessionOwner (Linphone-spec). No savedAudio category restore.
  private var speaker = true
  private var callVideo = false
  /// Interim ringback player (R3): no session calls, no watchdog. PJSIP ringback shim is the target.
  private var ringback: AVAudioPlayer?
  /// CallKit owns activation while it has the session
  private var callKitAudioActive = false
  private var callHolder: OLAudioHolderToken?
  private var pageMuted: Bool?
  /// FX-063: page-requested mute values whose CXSetMutedCallAction has not been performed yet (in tap order). Fast taps
  /// queue several transactions; matching each performed action against this FIFO (not just the latest value) keeps
  /// those echoes from being reported back to the page as new user mutes, which made the Mute button flicker.
  private var pendingPageMutes: [Bool] = []

  // MARK: - lifecycle / JS

  func start() {
    if started { return }
    started = true
    let cfg = CXProviderConfiguration()
    cfg.supportsVideo = true
    cfg.maximumCallGroups = 1
    cfg.maximumCallsPerCallGroup = 1
    cfg.supportedHandleTypes = [.generic]
    cfg.includesCallsInRecents = false
    // Bundled as a pod resource and resolved by CallKit from the app bundle.
    cfg.ringtoneSound = "openlounge-incoming.caf"
    let p = CXProvider(configuration: cfg)
    p.setDelegate(self, queue: nil) // main queue
    provider = p

    NotificationCenter.default.addObserver(
      self, selector: #selector(onRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onMediaServicesLost(_:)),
      name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onMediaServicesReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    // Linphone cut: no prepareHeadsetSession at launch — owner configures only for calls.
    OLCallAudioHost.shared.armAtLaunch()
    OLCallDiskLog.shared.mark("app-launch", "call manager ready")
    // Signal-identical activation chain: owner (sole AVAudioSession) → engine (WebRTC manual audio).
    OLAudioSessionOwner.shared.onActivated = { g in OLCallAudioEngine.shared.sessionActivated(g) }
    OLAudioSessionOwner.shared.onDeactivated = { g in OLCallAudioEngine.shared.sessionDeactivated(g) }
    NativeCallMedia.shared.onIsCaller = { [weak self] id in self?.call(id).map { !$0.incoming } ?? false }
    NativeCallMedia.shared.onVideo = { [weak self] id, local, remote in
      self?.emit(["type": "video", "callId": id, "local": local, "remote": remote])
    }
    signal.connect() // no-op until the page has mirrored a fresh access token (setAuth -> tokenUpdated)

    let r = PKPushRegistry(queue: DispatchQueue.main)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    registry = r
    NSLog("[OLCalls] PushKit + CallKit ready")

    // Simulator CI only (simctl launch with SIMCTL_CHILD_OL_SIM_RING=1): ring once through the normal push path.
    if ProcessInfo.processInfo.environment["OL_SIM_RING"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        let exp = Int((Date().timeIntervalSince1970 + 45) * 1000)
        self.handleIncoming(["type": "call_incoming", "callId": "simring1", "callerId": "u_sim", "callerName": "Sim Test",
                             "video": "0", "expiresAt": String(exp)], completion: {})
      }
    }
    #if targetEnvironment(simulator)
    // Simulator CI only: the CI sim has no CallKit host UI, so drive the native Decline request directly with the
    // push's decline token and NO session (nothing signed in): first → 200, the replay → 409.
    let env = ProcessInfo.processInfo.environment
    if let tok = env["OL_SIM_DECLINE_TOKEN"], !tok.isEmpty {
      let cid = env["OL_SIM_DECLINE_CALL"] ?? "simdecline1"
      for delay in [4.0, 9.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          NSLog("[OLCalls] sim: native decline with the push's decline token (session: %@)", OLCallAuth.fresh() == nil ? "none" : "fresh")
          self.declineOnServer(cid, declineToken: tok)
        }
      }
    }
    #endif
  }

  func attach(_ m: OpenLoungeCallsModule) {
    lock.lock(); module = m; jsReady = false; lock.unlock()
  }

  func detach(_ m: OpenLoungeCallsModule) {
    lock.lock(); if module === m { module = nil; jsReady = false }; lock.unlock()
  }

  /// Marks JS as listening and returns (then clears) actions that happened before, e.g. Answer on a cold start.
  func markReady() -> String {
    lock.lock()
    jsReady = true
    let now = Date().timeIntervalSince1970 * 1000
    let out = pending.filter { (($0["at"] as? Double) ?? 0) > now - 120_000 }
    pending.removeAll()
    lock.unlock()
    return Self.json(out)
  }

  var voipToken: String {
    lock.lock(); defer { lock.unlock() }
    return token
  }

  private func emit(_ action: [String: Any]) {
    var a = action
    a["at"] = Date().timeIntervalSince1970 * 1000
    lock.lock()
    let m = jsReady ? module : nil
    if m == nil {
      pending.append(a)
      if pending.count > 16 { pending.removeFirst() }
    }
    lock.unlock()
    m?.sendEvent("onCallAction", ["json": Self.json(a)])
  }

  private static func json(_ v: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) else { return "[]" }
    return s
  }

  private static func valid(_ id: String) -> Bool {
    return id.range(of: idPattern, options: .regularExpression) != nil
  }

  private func call(_ callId: String) -> OLCall? {
    return calls.values.first { $0.callId == callId && !$0.ended }
  }

  private var hasLiveCall: Bool { calls.values.contains { !$0.ended } }

  /// Stale-call clearing (Oct 17): before a new incoming call is reported, end anything CallKit still shows that is not
  /// a real live call, so a leftover ring/orphan never makes the new call look "busy" or stack behind a dead one.
  ///  - tracked incoming calls that were never answered and are >5 s past expiresAt → reportCall(ended, .unanswered)
  ///  - CallKit calls of this app (CXCallObserver) that are not ended and not in `calls` (orphaned UUIDs, e.g. after a
  ///    JS reload or a lost end event) → CXEndCallAction via CXCallController; reportCall(ended) if the request fails
  /// Answered/connected and outgoing calls are never touched.
  private func clearStaleCalls(now: Date = Date()) {
    for c in Array(calls.values) where c.incoming && !c.answered && !c.ended {
      if let e = c.expiresAt, now.timeIntervalSince(e) > 5 {
        NSLog("[OLCalls] clearing expired unanswered call before new incoming")
        c.ended = true
        stopTimers(c)
        calls[c.uuid] = nil
        provider?.reportCall(with: c.uuid, endedAt: nil, reason: .unanswered)
      }
    }
    for obs in controller.callObserver.calls where !obs.hasEnded && calls[obs.uuid] == nil {
      let uuid = obs.uuid
      NSLog("[OLCalls] ending orphaned CallKit call before new incoming")
      controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
        guard error != nil else { return }
        DispatchQueue.main.async { self?.provider?.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
      }
    }
  }

  // MARK: - PushKit

  public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    lock.lock(); token = hex; let m = jsReady ? module : nil; lock.unlock()
    m?.sendEvent("onVoipToken", ["token": hex])
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    lock.lock(); token = ""; let m = jsReady ? module : nil; lock.unlock()
    m?.sendEvent("onVoipToken", ["token": ""])
  }

  public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                           for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP else { completion(); return }
    var d: [String: String] = [:]
    for (k, v) in payload.dictionaryPayload {
      guard let key = k as? String else { continue }
      if let s = v as? String { d[key] = s } else if let n = v as? NSNumber { d[key] = n.stringValue }
    }
    handleIncoming(d, completion: completion)
  }

  private func handleIncoming(_ d: [String: String], completion: @escaping () -> Void) {
    guard let provider = provider else { completion(); return }
    let callId = d["callId"] ?? ""
    let ok = Self.valid(callId)
    var name = String((d["callerName"] ?? "").prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { name = "Open Lounge" }
    let video = d["video"] == "1" || d["video"] == "true"
    var expires: Date?
    if let e = d["expiresAt"], let ms = Double(e), ms > 0 { expires = Date(timeIntervalSince1970: ms / 1000) }
    let declineToken = d["declineToken"].flatMap { $0.range(of: Self.declineTokenPattern, options: .regularExpression) != nil ? $0 : nil }

    let update = CXCallUpdate()
    let handle = (d["callerId"] ?? "").isEmpty ? name : d["callerId"]!
    update.remoteHandle = CXHandle(type: .generic, value: String(handle.prefix(80)))
    update.localizedCallerName = name
    update.hasVideo = video
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    // Duplicate push for a call that's already ringing: it still has to be reported (same UUID → harmless error).
    if ok, let existing = call(callId) {
      provider.configuration = provider.configuration // Apple: setConfiguration before every reportNewIncomingCall
      provider.reportNewIncomingCall(with: existing.uuid, update: update) { _ in DispatchQueue.main.async { completion() } }
      return
    }

    clearStaleCalls() // orphans / expired rings must not make this call look busy
    // Every VoIP push must produce a reported call, even ones we won't ring for (then it's ended right away).
    let stale = !ok || (d["type"] ?? "call_incoming") != "call_incoming" || (expires.map { $0.timeIntervalSinceNow <= 1 } ?? false)
    let busy = !stale && hasLiveCall
    let uuid = UUID()
    let c = OLCall(callId: ok ? callId : "", uuid: uuid, incoming: true, video: video)
    c.expiresAt = expires
    c.declineToken = declineToken
    if !stale && !busy { calls[uuid] = c }

    provider.configuration = provider.configuration // Apple: setConfiguration before every reportNewIncomingCall

    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      DispatchQueue.main.async {
        completion()
        guard let self = self else { return }
        if let error = error {
          // Do Not Disturb / blocked / call limit: nothing rings.
          NSLog("[OLCalls] incoming call not shown: %@", error.localizedDescription)
          self.calls[uuid] = nil
          return
        }
        NSLog("[OLCalls] incoming call reported (stale=%d busy=%d)", stale ? 1 : 0, busy ? 1 : 0)
        if stale || busy {
          self.provider?.reportCall(with: uuid, endedAt: nil, reason: busy ? .unanswered : .remoteEnded)
          if busy { self.declineOnServer(callId, declineToken: declineToken) } // already in a call → reject as busy
          return
        }
        self.armRinging(c)
      }
    }
  }

  private func armRinging(_ c: OLCall) {
    let deadline = c.expiresAt ?? Date().addingTimeInterval(60)
    let left = max(1, min(120, deadline.timeIntervalSinceNow))
    c.expiryTimer = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { [weak self] _ in
      self?.endRinging(c, reason: .unanswered)
    }
    // The caller may hang up / another device may answer: a call_cancel FCM data message ends it via JS, and as a
    // backstop the call is polled while it rings (if a fresh access token is stored; rate limit is 30/min).
    c.pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      self?.poll(c)
    }
  }

  private func stopTimers(_ c: OLCall) {
    c.expiryTimer?.invalidate(); c.expiryTimer = nil
    c.pollTimer?.invalidate(); c.pollTimer = nil
  }

  private func endRinging(_ c: OLCall, reason: CXCallEndedReason) {
    guard calls[c.uuid] === c, !c.ended, !c.answered else { return }
    c.ended = true
    stopTimers(c)
    calls[c.uuid] = nil
    provider?.reportCall(with: c.uuid, endedAt: nil, reason: reason)
    endCallAudioSession()
  }

  private func poll(_ c: OLCall) {
    guard calls[c.uuid] === c, !c.answered, !c.ended else { stopTimers(c); return }
    guard let t = OLCallAuth.fresh() else { c.pollTimer?.invalidate(); c.pollTimer = nil; return }
    var req = URLRequest(url: Self.base.appendingPathComponent("api/calls/\(c.callId)"))
    req.timeoutInterval = 8
    req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
      let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
      var phase = ""
      if let data = data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let call = o["call"] as? [String: Any], let p = call["phase"] as? String { phase = p }
      DispatchQueue.main.async {
        guard let self = self else { return }
        if status == 404 || phase == "ended" { self.endRinging(c, reason: .remoteEnded) }
        else if phase == "active" { self.endRinging(c, reason: .answeredElsewhere) }
        else if status == 401 || status == 403 { c.pollTimer?.invalidate(); c.pollTimer = nil }
      }
    }.resume()
  }

  /// From JS: FCM call_cancel {callId, reason} (background data message) → stop the ring.
  func endExternally(callId: String, reason: String) {
    guard let c = call(callId), c.incoming, !c.answered else { return }
    let r: CXCallEndedReason
    switch reason {
    case "answered_elsewhere": r = .answeredElsewhere
    case "declined_elsewhere": r = .declinedElsewhere
    case "timeout", "missed", "expired": r = .unanswered
    default: r = .remoteEnded
    }
    endRinging(c, reason: r)
  }

  /// Sends the per-call decline token (works with no session) and the access token too when it's fresh (the server
  /// falls back to the session if the token is refused). Any 2xx/4xx answer is final: 409 = already declined/answered.
  private func declineOnServer(_ callId: String, declineToken: String?) {
    guard Self.valid(callId) else { return }
    let t = OLCallAuth.fresh()
    if t == nil && declineToken == nil {
      NSLog("[OLCalls] decline not sent: no decline token and no fresh access token (the caller's ring times out instead)")
      return
    }
    var req = URLRequest(url: Self.base.appendingPathComponent("api/calls/\(callId)/decline"))
    req.httpMethod = "POST"
    req.timeoutInterval = 15
    if let dt = declineToken { req.setValue(dt, forHTTPHeaderField: "X-Call-Decline-Token") }
    if let t = t { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data("{}".utf8)
    var bg = UIBackgroundTaskIdentifier.invalid
    let finish = {
      if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
    }
    bg = UIApplication.shared.beginBackgroundTask(withName: "openlounge-decline") { finish() }
    URLSession.shared.dataTask(with: req) { _, resp, _ in
      NSLog("[OLCalls] decline → %d (%@)", (resp as? HTTPURLResponse)?.statusCode ?? 0, declineToken != nil ? (t != nil ? "decline token + session" : "decline token") : "session")
      DispatchQueue.main.async { finish() }
    }.resume()
  }

  // MARK: - CallKit

  public func providerDidReset(_ provider: CXProvider) {
    OLCallDiskLog.shared.mark("callkit", "reset")
    for c in calls.values {
      stopTimers(c)
      if c.answered || !c.incoming { signal.hangup(c.callId); emit(["type": "hangup", "callId": c.callId]) }
      emitState(c, "terminated")
    }
    calls.removeAll()
    OLRtcCall.shared.close(sendBye: false)
    endCallAudioSession()
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    OLCallDiskLog.shared.mark("callkit", "answer")
    guard let c = calls[action.callUUID], !c.ended else { action.fail(); return }
    c.answered = true
    stopTimers(c)
    callVideo = c.video
    speaker = c.video // earpiece audio / speaker video
    guard beginCallAudioSession(c) else { action.fail(); return } // configure BEFORE fulfill
    action.fulfill() // CallKitIntegration.swift:372-373: answerCall(uuid) then fulfill
    emit(["type": "answer", "callId": c.callId, "video": c.video]) // JS: unlock + drop the lock-screen card only
    emitState(c, "connecting")
    presentNativeUI(c, phase: .active)
    acceptNative(c)
  }

  // MARK: - b104 native signaling + media

  /// PresentationCall.swift:1495/:1518 callSessionManager.accept → here call:accept on our socket, then media.
  private func acceptNative(_ c: OLCall) {
    c.native = true
    signal.accept(c.callId) { [weak self] r in
      guard let self, self.calls[c.uuid] === c, !c.ended else { return }
      if r["ok"] as? Bool != true {
        NSLog("[OLCalls] call:accept refused: %@", (r["reason"] as? String) ?? (r["error"] as? String) ?? "?")
        let reason: CXCallEndedReason = (r["reason"] as? String) == "answered_elsewhere" ? .answeredElsewhere : .failed
        self.endFromRemote(c, reason: reason)
        return
      }
      if let info = r["call"] as? [String: Any], let p = info["callerPlatform"] as? String { c.peerPlatform = p }
      self.connectMedia(c)
    }
  }

  private func connectMedia(_ c: OLCall) {
    // Single media path for every pairing (iOS/Android/web): one RTCPeerConnection per rtc contract v1.
    // Order: owner lease (CallKit didActivate) → WebRTC audio enabled → PC created with the live audio track.
    OLCallDiskLog.shared.mark("connect-media", "p2p peer=\(c.peerPlatform ?? "?")")
    OLCallAudioEngine.shared.startMedia(lease: { cb in
      OLAudioSessionOwner.shared.whenActive { r in cb(r.mapError { $0 as Error }) }
    }) { [weak self] r in
      guard let self, self.calls[c.uuid] === c, !c.ended else { return }
      if case .failure(let e) = r {
        OLCallDiskLog.shared.mark("audio-start-failed", e.description) // LOCAL: end, never relay/TURN
        return self.endFromRemote(c, reason: .failed)
      }
      OLRtcCall.shared.onTerminal = { [weak self] f in
        guard let self, self.calls[c.uuid] === c, !c.ended else { return }
        OLCallDiskLog.shared.mark("rtc-terminal", f.description)
        self.endFromRemote(c, reason: { if case .ended = f { return .remoteEnded } else { return .failed } }())
      }
      OLRtcCall.shared.start(self.signal, callId: c.callId, isCaller: !c.incoming) { [weak self] r in
        guard let self, self.calls[c.uuid] === c, !c.ended else { return }
        switch r {
        case .success: self.markConnected(c) // connected UI only after audio running AND ICE connected
        case .failure(let f):
          OLCallDiskLog.shared.mark("rtc-start-failed", f.description)
          self.endFromRemote(c, reason: .failed)
        }
      }
    }
  }

  private func markConnected(_ c: OLCall) {
    guard !c.connected else { return }
    c.connected = true
    stopTimers(c)
    stopRingback()
    if !c.incoming { provider?.reportOutgoingCall(with: c.uuid, connectedAt: Date()) }
    emitState(c, "active")
  }

  /// Remote end / answered elsewhere / refused: end CallKit, media, UI.
  private func endFromRemote(_ c: OLCall, reason: CXCallEndedReason) {
    guard !c.ended else { return }
    c.ended = true
    stopTimers(c)
    calls[c.uuid] = nil
    provider?.reportCall(with: c.uuid, endedAt: Date(), reason: reason)
    if c.native { OLRtcCall.shared.close(sendBye: false) }
    pageMuted = nil; pendingPageMutes = []
    stopRingback()
    emitState(c, "terminated")
    endCallAudioSession()
  }

  private func emitState(_ c: OLCall, _ state: String) {
    var a: [String: Any] = ["type": "state", "callId": c.callId, "state": state, "name": c.name, "video": c.video, "incoming": c.incoming]
    if let p = c.photo { a["photo"] = p }
    emit(a)
  }

  /// Server push on our own socket (server/calls/service.ts: call:incoming :389, call:state broadcast).
  private func onSignal(_ ev: String, _ d: [String: Any]) {
    // RingRTC session model: call signaling arrives E2E-sealed as rc:msg; plain rtc:signal is ignored (no dual path).
    if ev == "rc:msg" { DispatchQueue.main.async { OLRtcCall.shared.onRcMsg(d) }; return }
    if ev == "rtc:signal" { return }
    if ev == "call:p2p" { return } // legacy PJSIP direct leg: retired
    guard let info = d["call"] as? [String: Any], let callId = info["id"] as? String, Self.valid(callId) else { return }
    let phase = (info["phase"] as? String) ?? ""
    switch ev {
    case "call:incoming":
      let caller = (info["caller"] as? [String: Any]) ?? [:]
      if call(callId) == nil {
        var m: [String: Any] = ["type": "call:incoming", "callId": callId, "video": (info["video"] as? Bool) ?? false,
                                "name": (caller["name"] as? String) ?? ""]
        if let e = info["expiresAt"] as? NSNumber { m["expiresAt"] = e.doubleValue }
        if let ph = caller["photoUrl"] as? String { m["photo"] = ph }
        reportSocketIncoming(m)
      }
      if let c = call(callId) {
        if let p = info["callerPlatform"] as? String { c.peerPlatform = p }
        if let n = caller["name"] as? String, !n.isEmpty { c.name = String(n.prefix(80)) }
        if let ph = caller["photoUrl"] as? String, ph.hasPrefix("http") { c.photo = ph }
        emit(["type": "incoming", "callId": callId, "name": c.name, "video": c.video])
      }
      signal.ack(callId) // ring delivered → caller sees "Ringing…" (service.ts ack)
    case "call:state":
      guard let c = call(callId) else { return }
      if c.peerPlatform == nil, let p = info[c.incoming ? "callerPlatform" : "calleePlatform"] as? String { c.peerPlatform = p }
      if phase == "ended" {
        endFromRemote(c, reason: c.incoming && !c.answered ? .unanswered : .remoteEnded)
      } else if phase == "active" {
        if c.incoming && !c.answered { endRinging(c, reason: .answeredElsewhere) } // another device answered
        else if !c.incoming && !c.connected { connectMedia(c) } // callee answered our call
      }
    default:
      return
    }
  }

  /// Socket came back (signed in again): bind the live call to the new connection, like the web's resume → call:get.
  private func rebindLiveCalls() {
    for c in calls.values where c.native && !c.ended {
      signal.request("call:get", ["callId": c.callId]) { [weak self] r in
        guard let self, self.calls[c.uuid] === c else { return }
        let phase = ((r["call"] as? [String: Any])?["phase"] as? String) ?? ""
        if c.peerPlatform == nil, let p = (r["call"] as? [String: Any])?[c.incoming ? "callerPlatform" : "calleePlatform"] as? String { c.peerPlatform = p }
        if r["ok"] as? Bool != true || phase == "ended" { self.endFromRemote(c, reason: .remoteEnded) }
        else if phase == "active" && !c.incoming && !c.connected { self.connectMedia(c) }
      }
    }
  }

  /// The page's Call button (bridge.ts shim) → call:start on our socket; `done` gets the reply for the page.
  func dial(peerId: String, video: Bool, done: @escaping ([String: Any]) -> Void) {
    guard Self.valid(peerId) else { done(["ok": false, "error": "Couldn't start the call"]); return }
    clearStaleCalls()
    if hasLiveCall { done(["ok": false, "error": "You're already in a call", "reason": "self_busy"]); return }
    callVideo = video
    speaker = video // earpiece audio, speaker video; session configured in CXStartCallAction before fulfill
    signal.start(peerId: peerId, video: video) { [weak self] r in
      guard let self else { return }
      guard r["ok"] as? Bool == true, let info = r["call"] as? [String: Any], let callId = info["id"] as? String, Self.valid(callId) else {
        done(r) // busy / not allowed / unavailable: the page shows its own message, as before
        self.endCallAudioSession()
        return
      }
      done(["ok": false, "error": "", "reason": "native"]) // page stays out of the call (empty error = no toast)
      let glare = (info["callerId"] as? String) == peerId // both tapped Call: the server handed back their call to us
      let peer = ((glare ? info["caller"] : info["callee"]) as? [String: Any]) ?? [:]
      let c = OLCall(callId: callId, uuid: UUID(), incoming: false, video: video)
      c.native = true
      c.peerPlatform = (glare ? info["callerPlatform"] : info["calleePlatform"]) as? String
      if let n = peer["name"] as? String, !n.isEmpty { c.name = String(n.prefix(80)) }
      if let ph = peer["photoUrl"] as? String, ph.hasPrefix("http") { c.photo = ph }
      self.calls[c.uuid] = c
      self.emitState(c, "waiting")
      let a = CXStartCallAction(call: c.uuid, handle: CXHandle(type: .generic, value: c.name))
      a.isVideo = video
      a.contactIdentifier = c.name
      self.controller.request(CXTransaction(action: a)) { [weak self] err in
        DispatchQueue.main.async {
          guard let self else { return }
          if let err = err {
            NSLog("[OLCalls] outgoing CallKit call refused: %@", err.localizedDescription)
            self.startRingback()
          } else {
            self.presentNativeUI(c, phase: .outgoing)
            let u = CXCallUpdate()
            u.remoteHandle = CXHandle(type: .generic, value: c.name)
            u.localizedCallerName = c.name
            u.hasVideo = video
            u.supportsHolding = false
            u.supportsGrouping = false
            u.supportsUngrouping = false
            u.supportsDTMF = false
            self.provider?.reportCall(with: c.uuid, updated: u)
          }
          if glare {
            self.signal.accept(callId) { r in if r["ok"] as? Bool == true { self.connectMedia(c) } else { self.endFromRemote(c, reason: .failed) } }
          } else if (info["phase"] as? String) == "active" { self.connectMedia(c) }
        }
      }
    }
  }

  /// Our own call screen's End / Mute buttons → the same CallKit transactions the system UI uses.
  /// In-app incoming card Accept / Decline: the same CallKit actions as the system UI (CXAnswer / CXEnd below)
  func answerFromApp(_ callId: String) {
    guard let c = call(callId) else { return }
    controller.request(CXTransaction(action: CXAnswerCallAction(call: c.uuid))) { _ in }
  }
  func declineFromApp(_ callId: String) {
    guard let c = call(callId) else { return }
    controller.request(CXTransaction(action: CXEndCallAction(call: c.uuid))) { _ in }
  }

  func endFromApp() {
    guard let c = calls.values.first(where: { !$0.ended }) else { return }
    controller.request(CXTransaction(action: CXEndCallAction(call: c.uuid))) { [weak self] err in
      guard err != nil else { return }
      // CallKit never had this call (its start was refused): end it on the server and locally ourselves
      DispatchQueue.main.async {
        guard let self, self.calls[c.uuid] === c else { return }
        if c.incoming && !c.answered { self.signal.decline(c.callId) } else { self.signal.hangup(c.callId) }
        self.endFromRemote(c, reason: .remoteEnded)
      }
    }
  }

  func muteFromApp(_ muted: Bool) {
    guard let c = calls.values.first(where: { !$0.ended && ($0.answered || !$0.incoming) }) else { return }
    controller.request(CXTransaction(action: CXSetMutedCallAction(call: c.uuid, muted: muted))) { _ in }
  }

  /// A fresh access token was mirrored from the page: sign the socket in if it isn't.
  func tokenUpdated() { signal.connect() }

  /// Same incoming report the page path used (CallKit while the app is foreground and got the ring on the socket).
  private func reportSocketIncoming(_ m: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: m), let s = String(data: d, encoding: .utf8) else { return }
    handlePage(s)
    if let id = m["callId"] as? String, let c = call(id) { c.native = true }
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    OLCallDiskLog.shared.mark("callkit", "end")
    guard let c = calls[action.callUUID] else { action.fulfill(); return }
    c.ended = true
    stopTimers(c)
    calls[action.callUUID] = nil
    pageMuted = nil; pendingPageMutes = [] // FX-063: no stale mute echo leaks into the next call's start
    if c.incoming && !c.answered {
      // socket decline when signed in; the per-call decline token over HTTP otherwise (works with no session)
      if signal.authed { signal.decline(c.callId) } else { declineOnServer(c.callId, declineToken: c.declineToken) }
      c.declineToken = nil // single-use
      emit(["type": "decline", "callId": c.callId])
    } else {
      signal.hangup(c.callId) // PresentationCall.swift:1536 callSessionManager.drop(.hangUp)
      emit(["type": "hangup", "callId": c.callId])
    }
    OLRtcCall.shared.close(sendBye: true)
    emitState(c, "terminated")
    action.fulfill(withDateEnded: Date()) // CallKitIntegration.swift:392
    endCallAudioSession()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    OLCallDiskLog.shared.mark("callkit", "mute")
    action.fulfill()
    OLCallAudioEngine.shared.setMute(action.isMuted) // CallKitIntegration.swift:400-409 setCallMuted → engine
    emit(["type": "muted", "muted": action.isMuted]) // our call screen's Mute state
    if let i = pendingPageMutes.firstIndex(of: action.isMuted) { pendingPageMutes.removeSubrange(0...i); return } // echo of a page tap
    if pageMuted == action.isMuted { return } // already the page's state
    pageMuted = action.isMuted
    emit(["type": "mute", "muted": action.isMuted])
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    OLCallDiskLog.shared.mark("callkit", "start")
    guard let c = calls[action.callUUID] else { action.fail(); return }
    callVideo = c.video
    guard beginCallAudioSession(c) else { action.fail(); return } // configure BEFORE fulfill
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    OLCallDiskLog.shared.mark("callkit", "held")
    action.fail() // holding isn't supported
  }

  public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    OLCallDiskLog.shared.mark("callkit", "timedOut")
    action.fulfill()
  }

  /// Native-UI first cut (Claude step 5): present Swift call host; never leave 1:1 paint to RN/WebView.
  private func presentNativeUI(_ c: OLCall, phase: OLNativeCallHost.Phase) {
    let callId = c.callId, name = c.name, photo = c.photo, video = c.video
    Task { @MainActor in
      if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        if var top = win?.rootViewController {
          while let presented = top.presentedViewController { top = presented }
          OLNativeCallHost.shared.attach(to: top)
        }
      }
      OLNativeCallHost.shared.present(callId: callId, name: name, photoURL: photo, video: video, phase: phase)
    }
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    OLCallDiskLog.shared.mark("callkit", "didActivate")
    // Signal: forward activation to the sole owner → RTCAudioSession → lease resolves → engine enables audio.
    callKitAudioActive = true
    OLAudioSessionOwner.shared.callKitDidActivate(audioSession)
    OLAudioSessionOwner.shared.applyRoute(speakerWanted: speaker, headsetAttached: Self.headsetAttached())
    if calls.values.contains(where: { !$0.incoming && !$0.ended && !$0.answered && !$0.connected }) { startRingback() }
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    OLCallDiskLog.shared.mark("callkit", "didDeactivate")
    callKitAudioActive = false
    // Suspend media; KEEP the call holder (resume on the next didActivate). Teardown only on call end.
    OLAudioSessionOwner.shared.callKitDidDeactivate(audioSession)
  }

  // MARK: - page → native (src/calls.ts forwards {type:"call:*"} bridge messages)

  func handlePage(_ json: String) {
    guard let data = json.data(using: .utf8),
          let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let type = m["type"] as? String else { return }
    let callId = (m["callId"] as? String) ?? ""
    OLCallDiskLog.shared.mark("page", type) // page messages incl. reload-driven re-sync
    switch type {
    case "call:incoming":
      // Page got call:incoming over WS while App Lock is up — report CallKit the same way a VoIP push would.
      clearStaleCalls()
      guard Self.valid(callId), call(callId) == nil, !hasLiveCall else { return }
      let video = (m["video"] as? Bool) ?? false
      var name = String(((m["name"] as? String) ?? "").prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty { name = "Open Lounge" }
      let expires: Date? = {
        if let ms = m["expiresAt"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = m["expiresAt"] as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return Date().addingTimeInterval(45)
      }()
      let uuid = UUID()
      let c = OLCall(callId: callId, uuid: uuid, incoming: true, video: video)
      c.expiresAt = expires
      calls[uuid] = c
      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: name)
      update.localizedCallerName = name
      update.hasVideo = video
      update.supportsHolding = false
      update.supportsGrouping = false
      update.supportsUngrouping = false
      update.supportsDTMF = false
      if let p = provider { p.configuration = p.configuration } // Apple: setConfiguration before every reportNewIncomingCall
      provider?.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if let error = error {
            NSLog("[OLCalls] page incoming CallKit refused: %@", error.localizedDescription)
            self.calls[uuid] = nil
            return
          }
          self.armRinging(c)
        }
      }

    case "call:ringtonePrepare":
      // Linphone cut: CallKit owns ringtone. prepareRingtoneSession deleted — no-op.
      break

    case "call:outgoing":
      let video = (m["video"] as? Bool) ?? false
      // This value comes from the server-issued call media grant and is never inferred merely from video=true.
      let nativeMedia = video && ((m["nativeMedia"] as? Bool) ?? false)
      callVideo = video
      speaker = video // earpiece audio / speaker video
      guard Self.valid(callId), call(callId) == nil, !hasLiveCall else { return } // never reconfigure a live call
      var name = String(((m["name"] as? String) ?? "").prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty { name = "Open Lounge" }
      let c = OLCall(callId: callId, uuid: UUID(), incoming: false, video: video, nativeMedia: nativeMedia)
      calls[c.uuid] = c
      let a = CXStartCallAction(call: c.uuid, handle: CXHandle(type: .generic, value: name))
      a.isVideo = video
      a.contactIdentifier = name
      controller.request(CXTransaction(action: a)) { [weak self] err in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if let err = err {
            NSLog("[OLCalls] outgoing CallKit call refused: %@", err.localizedDescription)
            self.calls[c.uuid] = nil
            self.endCallAudioSession()
            return
          }
          let u = CXCallUpdate()
          u.remoteHandle = CXHandle(type: .generic, value: name)
          u.localizedCallerName = name
          u.hasVideo = video
          u.supportsHolding = false
          u.supportsGrouping = false
          u.supportsUngrouping = false
          u.supportsDTMF = false
          self.provider?.reportCall(with: c.uuid, updated: u)
        }
      }

    case "call:answering":
      // b83 restore (Donny 2026-11-04): Accept on the page's ring screen answers the CallKit call at the tap, so iOS shows
      // the native FaceTime-audio-style call UI / green status pill for in-app answers too (not only lock-screen answers).
      guard Self.valid(callId) else { return }
      if let c = call(callId), c.incoming, !c.answered {
        c.answeredInPage = true
        stopRingback()
        controller.request(CXTransaction(action: CXAnswerCallAction(call: c.uuid))) { err in
          if let err = err { NSLog("[OLCalls] in-app CXAnswerCallAction failed: %@", err.localizedDescription) }
        }
      }

    case "call:connected":
      stopRingback()
      if let c = call(callId) {
        c.connected = true
        stopTimers(c)
        callVideo = c.video
        presentNativeUI(c, phase: .active)
        if c.incoming && !c.answered {
          // answered on the page's own ring screen: move CallKit to the answered state without navigating again
          c.answeredInPage = true
          controller.request(CXTransaction(action: CXAnswerCallAction(call: c.uuid))) { _ in }
        } else if !c.incoming {
          provider?.reportOutgoingCall(with: c.uuid, connectedAt: Date())
        }
      }
      // ringback player released the session's output: have the page re-check its mic (captured at dial time, before
      // CallKit activated the session — WebKit can leave it muted → the callee hears nothing) and remote audio
      emit(["type": "audio", "reason": "connected"])
      // session was configured once at CallKit activation; adjusting it again after connect re-ran the voice
      // processing unit mid-call (volume pumping). Only a real device change or a speaker tap touches it now.

    case "call:ended":
      let targets = calls.values.filter { !$0.ended && (callId.isEmpty || $0.callId == callId) }
      for c in targets {
        c.ended = true
        stopTimers(c)
        presentNativeUI(c, phase: .ended)
        calls[c.uuid] = nil
        provider?.reportCall(with: c.uuid, endedAt: Date(), reason: .remoteEnded)
      }
      pageMuted = nil
      pendingPageMutes = []
      stopRingback()
      endCallAudioSession()

    case "call:muted":
      guard let muted = m["muted"] as? Bool else { return }
      pageMuted = muted
      if let c = calls.values.first(where: { !$0.ended && ($0.answered || !$0.incoming) }) {
        pendingPageMutes.append(muted)
        if pendingPageMutes.count > 8 { pendingPageMutes.removeFirst(pendingPageMutes.count - 8) }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: c.uuid, muted: muted))) { [weak self] error in
          guard error != nil else { return }
          DispatchQueue.main.async { if let i = self?.pendingPageMutes.firstIndex(of: muted) { self?.pendingPageMutes.remove(at: i) } }
        }
      }

    case "call:ringbackStop":
      // Linphone cut: web no longer owns ringback
      stopRingback()

    case "call:audioRoute":
      guard let sp = m["speaker"] as? Bool else { return }
      speaker = sp
      // Route picker (Oct 23): an explicit user pick of a kind/device wins until a device connects or disconnects.
      // Pages that only send speaker on/off keep the old behaviour (userRoute stays nil).
      if (m["user"] as? Bool) == true, let kind = m["route"] as? String {
        userRoute = (kind, (m["deviceId"] as? String) ?? kind)
      } else if (m["user"] as? Bool) != true {
        userRoute = nil
      }
      applySpeakerOverride()

    default:
      return
    }
  }

  // MARK: - audio session

  /// Wired, USB-C/Lightning, Bluetooth HFP/LE and CarPlay outputs that carry their own mic / are personal audio.
  static func headsetAttached(_ route: AVAudioSessionRouteDescription = OLAudioSessionOwner.shared.currentRoute) -> Bool {
    let ports: Set<AVAudioSession.Port> = [.headphones, .headsetMic, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .carAudio]
    return route.outputs.contains { ports.contains($0.portType) } || route.inputs.contains { ports.contains($0.portType) }
  }

  // prepareHeadsetSession REMOVED (Linphone cut) — rooms must request OLAudioSessionOwner when no call is held.

  /// Route changes we cause ourselves (setCategory → .categoryChange, overrideOutputAudioPort → .override) and
  /// WebKit's own re-configs must NOT reconfigure the session again: that fed back into itself during every ring and
  /// call (each pass reset the voice-processing unit → audible volume pumping). Only real device changes count.
  static func isDeviceRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep, .noSuitableRouteForCategory: return true
    default: return false // .categoryChange, .override, .routeConfigurationChange, .unknown
    }
  }

  @objc private func onRouteChange(_ n: Notification) {
    OLCallDiskLog.shared.mark("callkit", "audio-route-change")
    DispatchQueue.main.async {
      var reason = 0
      if let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt { reason = Int(v) }
      let why = AVAudioSession.RouteChangeReason(rawValue: UInt(reason)) ?? .unknown
      guard Self.isDeviceRouteChange(why) else { return }
      // Telegram ManagedAudioSession.swift:403-407: route change only refreshes the current route info
      self.emit(self.routePayload(reason: reason, source: "device"))
    }
  }

  // MARK: - route picker

  /// The user's explicit pick from the call screen's route sheet: (kind, device id). nil = automatic.
  private var userRoute: (kind: String, id: String)?

  static func routeKind(_ p: AVAudioSession.Port) -> String {
    switch p {
    case .builtInSpeaker: return "speaker"
    case .builtInReceiver, .builtInMic: return "earpiece"
    case .headphones, .headsetMic: return "wired"
    case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "bluetooth"
    case .usbAudio: return "usb"
    case .carAudio: return "car"
    default: return "system" // AirPlay, HDMI, …
    }
  }
  static func routeId(_ kind: String, _ name: String) -> String { kind == "speaker" || kind == "earpiece" ? kind : "\(kind):\(name)" }

  /// Current output + every output the user can pick: Speaker, Phone (iPhone receiver), and each headset input iOS
  /// offers (AirPods/Bluetooth HFP, wired, USB, CarPlay) plus an output-only headset that is currently playing.
  private func routePayload(reason: Int, source: String) -> [String: Any] {
    let s = OLAudioSessionOwner.shared
    let out = s.currentRoute.outputs.first
    let kind = out.map { Self.routeKind($0.portType) } ?? "system"
    let name = out?.portName ?? ""
    var routes: [[String: Any]] = [["kind": "speaker", "id": "speaker", "name": ""]]
    if UIDevice.current.userInterfaceIdiom == .phone { routes.append(["kind": "earpiece", "id": "earpiece", "name": ""]) }
    for i in s.availableInputs ?? [] where i.portType != .builtInMic {
      let k = Self.routeKind(i.portType)
      routes.append(["kind": k, "id": Self.routeId(k, i.portName), "name": i.portName, "port": i.portType.rawValue])
    }
    if !["speaker", "earpiece", "system"].contains(kind), !routes.contains(where: { ($0["id"] as? String) == Self.routeId(kind, name) }) {
      routes.append(["kind": kind, "id": Self.routeId(kind, name), "name": name, "port": out?.portType.rawValue ?? ""])
    }
    return ["type": "audioRoute", "headset": Self.headsetAttached(), "port": out?.portType.rawValue ?? "", "name": name,
            "reason": reason, "speaker": out?.portType == .builtInSpeaker, "kind": kind, "id": Self.routeId(kind, name),
            "routes": routes, "source": source, "user": userRoute != nil]
  }

  /// Apply an explicit pick. Speaker overrides any headset (like FaceTime); Phone moves input to the built-in mic so
  /// iOS routes output to the receiver; a headset pick selects that headset's input, which routes output to it too.
  private func applyUserRoute(_ pick: (kind: String, id: String)) {
    // all session mutation lives in OLAudioSessionOwner (sole AVAudioSession owner)
    OLAudioSessionOwner.shared.applyUserRoute(kind: pick.kind, id: pick.id) { Self.routeId(Self.routeKind($0.portType), $0.portName) } kindOf: { Self.routeKind($0.portType) }
  }

  /// Push call holder + configure playAndRecord/voiceChat BEFORE the CallKit action is fulfilled. Never setActive.
  /// Returns false (caller fails the CXAction) when configuration fails — errors are not swallowed.
  @discardableResult
  private func beginCallAudioSession(_ c: OLCall) -> Bool {
    OLCallDiskLog.shared.mark("callkit", "audio-session-configure")
    if callHolder == nil { callHolder = OLAudioSessionOwner.shared.push(.call) }
    OLCallAudioEngine.shared.prepare(callId: c.callId)
    do { try OLAudioSessionOwner.shared.configureForCall(); return true }
    catch { OLCallDiskLog.shared.mark("audio-configure-failed", "\(error)"); return false }
  }

  /// Pop call holder after didDeactivate / call end. Teardown only when popOnly is false (call end).
  private func endCallAudioSession(popOnly: Bool = false) {
    stopRingback()
    if !popOnly {
      pageMuted = nil
      pendingPageMutes = []
      speaker = true
      callVideo = false
    }
    OLCallAudioEngine.shared.end()
    OLAudioSessionOwner.shared.pop(callHolder)
    callHolder = nil
  }

  private func applySpeakerOverride() {
    if let pick = userRoute {
      applyUserRoute(pick)
      reportActualRoute(reason: "override")
      return
    }
    OLAudioSessionOwner.shared.applyRoute(speakerWanted: speaker, headsetAttached: Self.headsetAttached())
    reportActualRoute(reason: "override")
  }

  /// Speaker/Phone button truth: log and tell the page the route iOS actually chose (builtInSpeaker vs builtInReceiver
  /// vs headset), so the button reflects the real output instead of the last tap. Headset routing is untouched.
  private func reportActualRoute(reason: String) {
    let out = OLAudioSessionOwner.shared.currentRoute.outputs.first
    let port = out?.portType.rawValue ?? ""
    let onSpeaker = out?.portType == .builtInSpeaker
    NSLog("[OLCalls] audio route (%@): %@ speaker=%d", reason, port, onSpeaker ? 1 : 0)
    emit(routePayload(reason: 0, source: reason))
  }

  /// North-American ringback (440 + 480 Hz, 2 s on / 4 s off), synthesized once as 16-bit 48 kHz mono PCM WAV.
  static func ringbackWav() -> Data {
    let rate = 48_000, seconds = 6, n = rate * seconds, on = rate * 2, fade = rate / 100
    var pcm = Data(capacity: n * 2)
    for i in 0..<n {
      var v = 0.0
      if i < on {
        let t = Double(i) / Double(rate)
        let env = min(1.0, Double(min(i, on - i)) / Double(fade))
        v = 0.22 * env * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t))
      }
      var x = Int16(max(-1, min(1, v)) * 32767).littleEndian
      withUnsafeBytes(of: &x) { pcm.append(contentsOf: $0) }
    }
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
    return d
  }

  /// Interim ringback (Claude R3): AVAudioPlayer with NO session calls and NO watchdog. PJSIP shim is the target.
  private var wantRingback: Bool {
    calls.values.contains { !$0.incoming && !$0.ended && !$0.answered && !$0.connected }
  }

  private func startRingback() {
    guard wantRingback else { return }
    playRingback()
  }

  private func playRingback() {
    if ringback?.isPlaying == true { return }
    if let p = ringback, p.play() { return }
    do {
      let p = try AVAudioPlayer(data: Self.ringbackWav(), fileTypeHint: AVFileType.wav.rawValue)
      p.numberOfLoops = -1
      p.volume = 1
      p.prepareToPlay()
      _ = p.play()
      ringback = p
      NSLog("[OLCalls] interim native ringback started")
    } catch {
      NSLog("[OLCalls] interim ringback failed: %@", error.localizedDescription)
    }
  }

  @objc private func onInterruption(_ n: Notification) {
    OLCallDiskLog.shared.mark("callkit", "audio-interruption")
    DispatchQueue.main.async {
      guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let typ = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if typ == .began {
        // Linphone/Telegram: call holder survives; log only. CallKit sends didDeactivate if it takes the session.
        if self.hasLiveCall { NSLog("[OLCalls] interruption began (holder kept)") }
        return
      }
      // .ended: CallKit re-sends didActivate when it returns the session; the owner/engine resume on that
      // generation exactly once. No app-side setActive or reopen here.
      _ = typ
    }
  }

  @objc private func onMediaServicesLost(_ n: Notification) {
    OLCallDiskLog.shared.mark("callkit", "audio-media-services-lost")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.hasLiveCall else { return }
      _ = self // lost → wait for reset notification; nothing to reopen yet
    }
  }

  @objc private func onMediaServicesReset(_ n: Notification) {
    OLCallDiskLog.shared.mark("callkit", "audio-media-services-reset")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.hasLiveCall else { return }
      // Re-configure once; media resumes on the next CallKit activation (owner generation). No forced setActive.
      do { try OLAudioSessionOwner.shared.mediaServicesReset() }
      catch { OLCallDiskLog.shared.mark("audio-reset-failed", "\(error)") }
    }
  }

  private func stopRingback() {
    ringback?.stop()
    ringback = nil
  }

}
