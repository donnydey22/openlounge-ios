import AVFoundation
import CallKit
import Foundation
import PushKit
import Security
import UIKit

// Native call ringing for Open Lounge (NATIVE_SPEC.md §3).
//
//   VoIP push (PushKit) ─▶ report a CallKit incoming call IMMEDIATELY (iOS kills/throttles apps that don't)
//   CallKit Answer      ─▶ JS opens https://openlounge.app/call/<id>?accept=1 in the WebView
//   CallKit Decline     ─▶ POST /api/calls/<id>/decline natively (works with the WebView not loaded). Build 19: with
//                          the push's per-call decline token (X-Call-Decline-Token: call+callee scoped, expires with
//                          the ring, single-use), so Decline works even when the 1-hour session has expired.
//   CallKit End/Mute    ─▶ JS injects openlounge:native-call {call:hangup | call:mute}
//   page call:*         ─▶ mirror into CallKit (outgoing call, connected, ended, muted) + audio route
//
// Audio: while a call is up the app's AVAudioSession is playAndRecord + voiceChat/videoChat with
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

  // audio
  private var savedAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private var speaker = true
  private var callVideo = false
  /// native outgoing ringback (the page skips its own when window.__olNativeRingback is set)
  private var ringback: AVAudioPlayer?
  /// 1 s watchdog while an outgoing call rings: restarts the player whenever it is not playing (b31 root cause: WebKit's
  /// mic capture / WebRTC audio unit re-activating the shared AVAudioSession right after CallKit activation stopped the
  /// AVAudioPlayer, and nothing ever restarted it) and reports {playing} to the page so the web ring can take over.
  private var ringbackTimer: Timer?
  private var ringbackReported: Bool?
  /// CallKit owns activation while it has the session; activating it ourselves mid-call re-routes WebKit's capture
  private var callKitAudioActive = false
  /// the page's web ringback owns the tone for this call (call:ringbackStop) → native stays silent
  private var webOwnsRingback = false
  private var pageMuted: Bool?

  // MARK: - lifecycle / JS

  func start() {
    OLNativeAudio.setUp()
    if started { return }
    started = true
    let cfg = CXProviderConfiguration()
    cfg.supportsVideo = true
    cfg.maximumCallGroups = 1
    cfg.maximumCallsPerCallGroup = 1
    cfg.supportedHandleTypes = [.generic]
    cfg.includesCallsInRecents = false
    let p = CXProvider(configuration: cfg)
    p.setDelegate(self, queue: nil) // main queue
    provider = p

    NotificationCenter.default.addObserver(
      self, selector: #selector(onRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    prepareHeadsetSession()

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
    restoreAudioIfIdle()
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
    for c in calls.values {
      stopTimers(c)
      if c.answered || !c.incoming { emit(["type": "hangup", "callId": c.callId]) }
    }
    calls.removeAll()
    restoreAudioIfIdle()
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let c = calls[action.callUUID], !c.ended else { action.fail(); return }
    c.answered = true
    stopTimers(c)
    callVideo = c.video
    configureAudio()
    action.fulfill()
    if !c.answeredInPage { emit(["type": "answer", "callId": c.callId, "video": c.video]) }
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard let c = calls[action.callUUID] else { action.fulfill(); return }
    c.ended = true
    stopTimers(c)
    calls[action.callUUID] = nil
    if c.incoming && !c.answered {
      declineOnServer(c.callId, declineToken: c.declineToken)
      c.declineToken = nil // single-use
      emit(["type": "decline", "callId": c.callId])
    } else {
      emit(["type": "hangup", "callId": c.callId])
    }
    action.fulfill()
    restoreAudioIfIdle()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
    if pageMuted == action.isMuted { return } // echo of a page-initiated change
    pageMuted = action.isMuted
    emit(["type": "mute", "muted": action.isMuted])
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    guard let c = calls[action.callUUID] else { action.fail(); return }
    callVideo = c.video
    configureAudio()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    action.fail() // holding isn't supported
  }

  public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    callKitAudioActive = true
    configureAudio()
    // Ungranted video calls retain the established WKWebView-media behavior, so their native WebRTC audio unit must
    // remain off. The explicit native-video caller marker is the sole video exception: its one app-owned mic+camera
    // connection must be enabled only after CallKit has handed over the videoChat session. Audio-only native calls
    // remain unchanged.
    let nativeVideo = calls.values.contains(where: { !$0.ended && $0.nativeMedia })
    if !callVideo || nativeVideo {
      OLNativeAudio.didActivate(audioSession, video: nativeVideo)
    }
    // outgoing call still waiting for the callee: ring back natively on the CallKit session (survives the session swap
    // that left WKWebView's <audio>/AudioContext "playing" but silent)
    if calls.values.contains(where: { !$0.incoming && !$0.ended && !$0.answered && !$0.connected }) { startRingback() }
    // CallKit activating the session (outgoing CXStartCallAction, or answer) interrupts WebKit's AudioContext and
    // pauses the page's ring <audio>: the web ringback went silent the moment the call was mirrored into CallKit.
    // Tell JS so it re-runs the page's audio resume (AudioContext + ring element) on the new session.
    emit(["type": "audio", "reason": "callkit-activate"])
    // WebKit re-binds its audio units a few hundred ms after CallKit hands over the session; a single kick can land
    // before that and the ring <audio> / remote voice stays paused (ring "plays briefly then stops", silent audio-only
    // call). Re-kick twice more — the page side is idempotent.
    for delay in [0.35, 1.2] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self, self.hasLiveCall else { return }
        self.emit(["type": "audio", "reason": "callkit-activate-settle"])
      }
    }
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    callKitAudioActive = false
    OLNativeAudio.didDeactivate(audioSession)
  }

  // MARK: - page → native (src/calls.ts forwards {type:"call:*"} bridge messages)

  func handlePage(_ json: String) {
    guard let data = json.data(using: .utf8),
          let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let type = m["type"] as? String else { return }
    let callId = (m["callId"] as? String) ?? ""
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
      // page is about to play the incoming ringtone (tones.ts): ring/speaker session, not a left-over call session
      prepareRingtoneSession()

    case "call:outgoing":
      let video = (m["video"] as? Bool) ?? false
      // This value comes from the server-issued call media grant and is never inferred merely from video=true.
      let nativeMedia = video && ((m["nativeMedia"] as? Bool) ?? false)
      callVideo = video
      speaker = true
      webOwnsRingback = false
      guard Self.valid(callId), call(callId) == nil, !hasLiveCall else { configureAudio(); return }
      // pre-call prep (Android's audio-focus step): category/mode/options for the call are set BEFORE the CallKit
      // transaction, so activation only flips the already-configured session live instead of reconfiguring it under
      // WebKit's running capture. Not activated here — CallKit owns activation.
      configureAudio()
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
            self.configureAudio() // still route ringback to the speaker
            // the page skips its ringback inside the app: without CallKit activation, ring back here directly
            if (try? AVAudioSession.sharedInstance().setActive(true)) != nil { self.startRingback() }
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

    case "call:connected":
      stopRingback()
      if let c = call(callId) {
        c.connected = true
        stopTimers(c)
        callVideo = c.video
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
        calls[c.uuid] = nil
        provider?.reportCall(with: c.uuid, endedAt: Date(), reason: .remoteEnded)
      }
      pageMuted = nil
      stopRingback()
      restoreAudioIfIdle(force: true)

    case "call:muted":
      guard let muted = m["muted"] as? Bool else { return }
      pageMuted = muted
      if let c = calls.values.first(where: { !$0.ended && ($0.answered || !$0.incoming) }) {
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: c.uuid, muted: muted))) { _ in }
      }

    case "call:ringbackStop":
      webOwnsRingback = true
      stopRingback()

    case "call:audioRoute":
      guard let sp = m["speaker"] as? Bool else { return }
      speaker = sp
      applySpeakerOverride()

    default:
      return
    }
  }

  // MARK: - audio session

  /// Wired, USB-C/Lightning, Bluetooth HFP/LE and CarPlay outputs that carry their own mic / are personal audio.
  static func headsetAttached(_ route: AVAudioSessionRouteDescription = AVAudioSession.sharedInstance().currentRoute) -> Bool {
    let ports: Set<AVAudioSession.Port> = [.headphones, .headsetMic, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .carAudio]
    return route.outputs.contains { ports.contains($0.portType) } || route.inputs.contains { ports.contains($0.portType) }
  }

  /// Rooms (WebRTC in WKWebView) and calls: playAndRecord that lets a headset's mic and speaker route automatically,
  /// and the loudspeaker only when nothing is attached.
  private func prepareHeadsetSession() {
    let s = AVAudioSession.sharedInstance()
    var opts: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    if !Self.headsetAttached() { opts.insert(.defaultToSpeaker) }
    try? s.setCategory(.playAndRecord, mode: .default, options: opts)
  }

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
    DispatchQueue.main.async {
      let headset = Self.headsetAttached()
      var reason = 0
      if let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt { reason = Int(v) }
      let why = AVAudioSession.RouteChangeReason(rawValue: UInt(reason)) ?? .unknown
      guard Self.isDeviceRouteChange(why) else { return }
      if self.savedAudio != nil { self.configureAudio() } else { self.prepareHeadsetSession() }
      let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
      self.emit(["type": "audioRoute", "headset": headset, "port": out?.portType.rawValue ?? "", "name": out?.portName ?? "", "reason": reason])
    }
  }

  private func configureAudio() {
    let s = AVAudioSession.sharedInstance()
    if savedAudio == nil { savedAudio = (s.category, s.mode, s.categoryOptions) }
    var opts: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    let headset = Self.headsetAttached()
    // never force the loudspeaker while a headset is attached; it falls back to speaker when removed
    if speaker && !headset { opts.insert(.defaultToSpeaker) }
    let mode: AVAudioSession.Mode = callVideo ? .videoChat : .voiceChat
    // idempotent: every redundant setCategory / override is itself a route change + voice-processing reset
    if s.category != .playAndRecord || s.mode != mode || s.categoryOptions != opts {
      do {
        try s.setCategory(.playAndRecord, mode: mode, options: opts)
      } catch {
        NSLog("[OLCalls] setCategory failed: %@", error.localizedDescription)
      }
    }
    // FaceTime-style low latency: 10 ms IO buffer and the 48 kHz Opus clock (no resample in the voice path).
    // Preferences only — iOS clamps to what the route supports and never throws the call off the session.
    if s.preferredSampleRate != 48_000 { try? s.setPreferredSampleRate(48_000) }
    if abs(s.preferredIOBufferDuration - 0.01) > 0.0005 { try? s.setPreferredIOBufferDuration(0.01) }
    // Loudness (Oct 16, Donny/Keiko "not loud enough"): full mic input gain where the route allows it (voiceChat's
    // own AGC still levels it); a no-op on routes that don't expose a settable gain.
    if s.isInputGainSettable && s.inputGain < 1.0 { try? s.setInputGain(1.0) }
    let wantSpeaker = speaker && !headset
    let onSpeaker = s.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    if wantSpeaker != onSpeaker {
      do {
        try s.overrideOutputAudioPort(wantSpeaker ? .speaker : .none)
      } catch {
        // fails while the session is inactive; defaultToSpeaker covers that case
      }
    }
  }

  private func applySpeakerOverride() {
    let s = AVAudioSession.sharedInstance()
    let wantSpeaker = speaker && !Self.headsetAttached()
    let onSpeaker = s.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    if wantSpeaker != onSpeaker { try? s.overrideOutputAudioPort(wantSpeaker ? .speaker : .none) }
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

  /// an outgoing call is still waiting for the callee and the web has not taken the ring over
  private var wantRingback: Bool {
    !webOwnsRingback && calls.values.contains { !$0.incoming && !$0.ended && !$0.answered && !$0.connected }
  }

  private func startRingback() {
    guard wantRingback else { return }
    if ringbackTimer == nil {
      let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.ringbackTick() }
      RunLoop.main.add(t, forMode: .common)
      ringbackTimer = t
    }
    playRingback()
  }

  private func playRingback() {
    if ringback?.isPlaying == true { return reportRingback(true) }
    if !callKitAudioActive { try? AVAudioSession.sharedInstance().setActive(true) }
    if let p = ringback, p.play() { NSLog("[OLCalls] native ringback resumed"); return reportRingback(true) }
    do {
      let p = try AVAudioPlayer(data: Self.ringbackWav(), fileTypeHint: AVFileType.wav.rawValue)
      p.numberOfLoops = -1
      p.volume = 1
      p.prepareToPlay()
      let ok = p.play()
      ringback = p // retained for the whole ring
      NSLog("[OLCalls] native ringback started ok=%d", ok ? 1 : 0)
      reportRingback(ok && p.isPlaying)
    } catch {
      NSLog("[OLCalls] native ringback failed: %@", error.localizedDescription)
      reportRingback(false)
    }
  }

  private func ringbackTick() {
    guard wantRingback else { return stopRingback() }
    if ringback?.isPlaying != true {
      NSLog("[OLCalls] ringback watchdog: not playing, restarting")
      reportRingback(false)
      playRingback()
    } else {
      reportRingback(true)
    }
  }

  private func reportRingback(_ playing: Bool) {
    if ringbackReported == playing && playing == false { return }
    ringbackReported = playing
    emit(["type": "ringback", "playing": playing])
  }

  @objc private func onInterruption(_ n: Notification) {
    DispatchQueue.main.async {
      guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
      if self.wantRingback { self.playRingback() }
      // GSM call / Siri / alarm over: WebKit leaves the remote <audio> paused and the mic muted. Kick the page so it
      // resumes playback and recaptures the mic (checkMicAlive) — the call otherwise stays silent both ways.
      if self.hasLiveCall { self.emit(["type": "audio", "reason": "interruption-ended"]) }
    }
  }

  private func stopRingback() {
    ringbackTimer?.invalidate()
    ringbackTimer = nil
    ringback?.stop()
    ringback = nil
    if ringbackReported == true { emit(["type": "ringback", "playing": false]) }
    ringbackReported = nil
  }

  /// before the incoming ringtone: native audio engine stopped, playAndRecord/.default/.defaultToSpeaker re-applied
  /// and the loudspeaker forced (no headset) — ringtone only, never while a call is live
  private func prepareRingtoneSession() {
    guard !hasLiveCall else { return }
    OLNativeAudio.stopIdle()
    prepareHeadsetSession()
    let s = AVAudioSession.sharedInstance()
    try? s.setActive(true)
    try? s.overrideOutputAudioPort(Self.headsetAttached() ? .none : .speaker)
  }

  private func restoreAudioIfIdle(force: Bool = false) {
    guard !hasLiveCall, let saved = savedAudio else { return }
    savedAudio = nil
    speaker = true
    callVideo = false
    stopRingback()
    pageMuted = nil
    let s = AVAudioSession.sharedInstance()
    try? s.overrideOutputAudioPort(.none)
    try? s.setCategory(saved.0, mode: saved.1, options: saved.2)
    OLNativeAudio.stopIdle()
    prepareHeadsetSession()
    _ = force
  }
}
