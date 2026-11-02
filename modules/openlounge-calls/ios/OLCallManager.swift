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

  /// Only a short-lived canonical CallKit identity is persisted. Credentials and decline tokens
  /// are deliberately never stored here; a fresh VoIP delivery supplies those when needed.
  private struct PersistedIncomingIdentity: Codable {
    let uuid: String
    let expiresAt: TimeInterval
  }
  private static let incomingIdentityKey = "ol.incomingCallIdentities.v1"
  private var incomingIdentities: [String: PersistedIncomingIdentity] = {
    guard let data = UserDefaults.standard.data(forKey: OLCallManager.incomingIdentityKey),
          let value = try? JSONDecoder().decode([String: PersistedIncomingIdentity].self, from: data) else { return [:] }
    return value
  }()

  private var started = false
  private var provider: CXProvider?
  private let controller = CXCallController()
  private var calls: [UUID: OLCall] = [:]
  /// callIds answered on this device's page ring screen (call:answering), so the server's "answered" cancel is ignored
  private var pageAnswered: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ol.answeredHere") ?? []) {
    didSet { UserDefaults.standard.set(Array(pageAnswered.suffix(16)), forKey: "ol.answeredHere") }
  }
  /// this device answered callId (page Accept or CallKit UI): the server's "answered" cancel must not end it here
  private func markAnsweredHere(_ callId: String) {
    guard Self.valid(callId) else { return }
    pageAnswered.insert(callId)
    if pageAnswered.count > 16 { pageAnswered.removeFirst() }
  }

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
  /// b73: native WebRTC audio unit enabled for the current CallKit activation
  private var nativeAudioOn = false
  /// the page's web ringback owns the tone for this call (call:ringbackStop) → native stays silent
  private var webOwnsRingback = false
  private var pageMuted: Bool?
  /// FX-063: page-requested mute values whose CXSetMutedCallAction has not been performed yet (in tap order). Fast taps
  /// queue several transactions; matching each performed action against this FIFO (not just the latest value) keeps
  /// those echoes from being reported back to the page as new user mutes, which made the Mute button flicker.
  private var pendingPageMutes: [Bool] = []

  // MARK: - lifecycle / JS

  func start() {
    OLNativeAudio.setUp()
    if started { return }
    started = true
    provider = OLTelecomRegistration.shared.start(providerDelegate: self, pushDelegate: self)

    NotificationCenter.default.addObserver(
      self, selector: #selector(onRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(onInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    prepareHeadsetSession()
    NSLog("[OLCalls] PushKit + CallKit ready through telecom core")

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

  private func saveIncomingIdentities() {
    let now = Date().timeIntervalSince1970
    incomingIdentities = incomingIdentities.filter { $0.value.expiresAt > now - 5 }
    if incomingIdentities.count > 16 {
      let keep = incomingIdentities.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(16)
      incomingIdentities = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
    if let data = try? JSONEncoder().encode(incomingIdentities) {
      UserDefaults.standard.set(data, forKey: Self.incomingIdentityKey)
    }
  }

  private func persistCanonicalIdentity(_ c: OLCall) {
    guard c.incoming, c.reported, Self.valid(c.callId) else { return }
    let expires = c.expiresAt?.timeIntervalSince1970 ?? Date().addingTimeInterval(60).timeIntervalSince1970
    incomingIdentities[c.callId] = PersistedIncomingIdentity(uuid: c.uuid.uuidString, expiresAt: expires)
    saveIncomingIdentities()
  }

  private func canonicalUUID(for callId: String, now: Date = Date()) -> UUID? {
    guard let stored = incomingIdentities[callId] else { return nil }
    guard stored.expiresAt > now.timeIntervalSince1970 - 5, let uuid = UUID(uuidString: stored.uuid) else {
      incomingIdentities[callId] = nil
      saveIncomingIdentities()
      return nil
    }
    return uuid
  }

  private func removeCanonicalIdentity(_ c: OLCall) {
    guard c.incoming else { return }
    incomingIdentities[c.callId] = nil
    saveIncomingIdentities()
  }

  /// Provider callbacks and native reporting share one redacted diagnostic shape.
  private func traceProviderCallback(_ event: String, uuid: UUID? = nil) {
    let c = uuid.flatMap { calls[$0] }
    let sinceSignalMs = c.map { Int(Date().timeIntervalSince($0.signalingAt) * 1000) } ?? -1
    let snapshot = c?.redactedSnapshot() ?? "missing"
    NSLog("[OLCalls] client-diag callback=%@ uuid=%@ sinceSignalMs=%d session={%@}", event, uuid?.uuidString ?? "-", sinceSignalMs, snapshot)
  }

  private func finishIncomingReport(_ c: OLCall) {
    c.reportWatchdog?.cancel()
    c.reportWatchdog = nil
    let completions = c.reportCompletions
    c.reportCompletions.removeAll()
    for completion in completions { completion() }
  }

  private func armIncomingReportWatchdog(_ c: OLCall) {
    let work = DispatchWorkItem { [weak self, weak c] in
      guard let self, let c, self.calls[c.uuid] === c, c.reporting, !c.reported else { return }
      c.fallbackShown = true
      self.traceProviderCallback("incoming-report-watchdog", uuid: c.uuid)
      NSLog("[OLCalls] WATCHDOG: incoming CallKit report has not completed within 2 s; showing native fallback")
      self.emit(["type": "incomingFallback", "callId": c.callId, "name": c.callerName, "video": c.video])
    }
    c.reportWatchdog = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }

  /// The initial report runs immediately in PushKit's delivery turn. Only a failed report is retried,
  /// on the same canonical UUID, with bounded backoff. Successful duplicate ingress never reports again.
  private func reportIncoming(_ c: OLCall, update: CXCallUpdate, stale: Bool, busy: Bool) {
    guard let provider else {
      c.reporting = false
      finishIncomingReport(c)
      calls[c.uuid] = nil
      emit(["type": "callFailure", "callId": c.callId, "reason": "callkit-provider-missing"])
      return
    }
    let attempt = c.reportAttempts
    c.reportAttempts += 1
    c.reporting = true
    traceProviderCallback("report-incoming-attempt-\(attempt + 1)", uuid: c.uuid)
    provider.reportNewIncomingCall(with: c.uuid, update: update) { [weak self, weak c] error in
      DispatchQueue.main.async {
        guard let self, let c, self.calls[c.uuid] === c else { return }
        if let error {
          let backoff: [TimeInterval] = [0.20, 0.60]
          if attempt < backoff.count {
            let delay = backoff[attempt]
            NSLog("[OLCalls] incoming report attempt %d failed (%@); retrying in %.2f s", attempt + 1, error.localizedDescription, delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak c] in
              guard let self, let c, self.calls[c.uuid] === c, !c.reported else { return }
              self.reportIncoming(c, update: update, stale: stale, busy: busy)
            }
            return
          }
          c.reporting = false
          self.finishIncomingReport(c)
          self.calls[c.uuid] = nil
          self.traceProviderCallback("report-incoming-failed", uuid: c.uuid)
          NSLog("[OLCalls] incoming call report failed after %d attempts: %@", c.reportAttempts, error.localizedDescription)
          self.emit(["type": "callFailure", "callId": c.callId, "reason": "callkit-report-failed"])
          return
        }

        c.reporting = false
        c.reported = true
        if !stale && !busy { self.persistCanonicalIdentity(c) }
        self.finishIncomingReport(c)
        self.traceProviderCallback("report-incoming-success", uuid: c.uuid)
        NSLog("[OLCalls] incoming call reported once (stale=%d busy=%d)", stale ? 1 : 0, busy ? 1 : 0)
        if stale || busy {
          self.provider?.reportCall(with: c.uuid, endedAt: nil, reason: busy ? .unanswered : .remoteEnded)
          if busy { self.declineOnServer(c.callId, declineToken: c.declineToken) }
          self.calls[c.uuid] = nil
          return
        }
        self.armRinging(c)
      }
    }
  }

  /// Stale-call clearing (Oct 17): before a new incoming call is reported, end anything CallKit still shows that is not
  /// a real live call, so a leftover ring/orphan never makes the new call look "busy" or stack behind a dead one.
  ///  - tracked incoming calls that were never answered and are >5 s past expiresAt → reportCall(ended, .unanswered)
  ///  - CallKit calls of this app (CXCallObserver) that are not ended and not in `calls` (orphaned UUIDs, e.g. after a
  ///    JS reload or a lost end event) → CXEndCallAction via CXCallController; reportCall(ended) if the request fails
  /// Answered/connected and outgoing calls are never touched.
  private func clearStaleCalls(now: Date = Date(), preserving preservedUUID: UUID? = nil) {
    for c in Array(calls.values) where c.incoming && !c.answered && !c.ended {
      if let e = c.expiresAt, now.timeIntervalSince(e) > 5 {
        NSLog("[OLCalls] clearing expired unanswered call before new incoming")
        c.ended = true
        stopTimers(c)
        removeCanonicalIdentity(c)
        calls[c.uuid] = nil
        provider?.reportCall(with: c.uuid, endedAt: nil, reason: .unanswered)
      }
    }
    for obs in controller.callObserver.calls where !obs.hasEnded && obs.uuid != preservedUUID && calls[obs.uuid] == nil {
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
    guard provider != nil else { completion(); return }
    let callId = d["callId"] ?? ""
    let ok = Self.valid(callId)
    var name = String((d["callerName"] ?? "").prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { name = "Open Lounge" }
    let video = d["video"] == "1" || d["video"] == "true"
    var expires: Date?
    if let e = d["expiresAt"], let ms = Double(e), ms > 0 { expires = Date(timeIntervalSince1970: ms / 1000) }
    // b80: Android caller, audio-only → this call's media is the native Swift lane only (prepared before didActivate)
    if Self.valid(callId), !video, (d["callerPlatform"] ?? d["peerPlatform"] ?? "").lowercased() == "android" {
      OLNativeAudioLane.markAndroidCall(callId)
    }
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

    let persistedUUID = ok ? canonicalUUID(for: callId) : nil
    clearStaleCalls(preserving: persistedUUID) // orphans / expired rings must not make this call look busy

    // A PushKit/page race or APNs redelivery reuses the canonical CallSession/UUID. It must
    // complete this push delivery but must never call reportNewIncomingCall a second time.
    if ok, let existing = call(callId) {
      existing.callerName = name
      existing.video = video
      if let expires { existing.expiresAt = expires }
      if let declineToken { existing.declineToken = declineToken }
      traceProviderCallback("incoming-duplicate", uuid: existing.uuid)
      completion()
      return
    }

    // Every VoIP push must produce a reported call, even ones we won't ring for (then it's ended right away).
    let stale = !ok || (d["type"] ?? "call_incoming") != "call_incoming" || (expires.map { $0.timeIntervalSinceNow <= 1 } ?? false)
    if !stale, let uuid = persistedUUID, !hasLiveCall {
      let recovered = OLCall(callId: callId, uuid: uuid, incoming: true, video: video)
      recovered.callerName = name
      recovered.expiresAt = expires
      recovered.declineToken = declineToken
      recovered.reported = true
      calls[uuid] = recovered
      armRinging(recovered)
      traceProviderCallback("incoming-recovered", uuid: uuid)
      NSLog("[OLCalls] recovered canonical incoming UUID after relaunch; no second CallKit report")
      completion()
      return
    }
    let busy = !stale && hasLiveCall
    let uuid = UUID()
    let c = OLCall(callId: ok ? callId : "", uuid: uuid, incoming: true, video: video)
    c.callerName = name
    c.expiresAt = expires
    c.declineToken = declineToken
    c.reportCompletions.append(completion)
    // Keep every report attempt in the canonical table until it completes. This also prevents
    // a second invalid/busy delivery from creating a second concurrent CallKit report.
    calls[uuid] = c
    armIncomingReportWatchdog(c)
    reportIncoming(c, update: update, stale: stale, busy: busy)
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

  /// Terminal native cleanup always operates on the complete local call set. This avoids
  /// leaving an orphaned ringing UUID behind after a provider reset or global failure.
  private func endAllCalls(reason: CXCallEndedReason, reportToProvider: Bool) {
    let targets = Array(calls.values)
    for c in targets {
      c.ended = true
      stopTimers(c)
      c.reportWatchdog?.cancel()
      c.reportWatchdog = nil
      finishIncomingReport(c)
      removeCanonicalIdentity(c)
      if c.answered || !c.incoming { emit(["type": "hangup", "callId": c.callId]) }
      if reportToProvider { provider?.reportCall(with: c.uuid, endedAt: Date(), reason: reason) }
      calls[c.uuid] = nil
    }
  }

  private func endRinging(_ c: OLCall, reason: CXCallEndedReason) {
    guard calls[c.uuid] === c, !c.ended, !c.answered else { return }
    c.ended = true
    stopTimers(c)
    removeCanonicalIdentity(c)
    calls[c.uuid] = nil
    provider?.reportCall(with: c.uuid, endedAt: nil, reason: reason)
    resetAudioState("ring-end")
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
    // build 72: the server's accept cancel ("answered") also reaches the iPhone that answered on the page. Ending its
    // CallKit call there deactivated the session mid-connect (mic 0, 7b24cedb). Only the page knows it answered here.
    if reason == "answered" && pageAnswered.contains(callId) { return }
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
    traceProviderCallback("provider-reset")
    endAllCalls(reason: .failed, reportToProvider: false)
    resetAudioState("provider-reset")
    restoreAudioIfIdle()
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    traceProviderCallback("answer-action", uuid: action.callUUID)
    guard let c = calls[action.callUUID], !c.ended else { action.fail(); return }
    c.answered = true
    markAnsweredHere(c.callId)
    stopTimers(c)
    callVideo = c.video
    // Incoming CallKit owns the audio session. Outgoing behavior is retained exactly as before.
    if !c.incoming { configureAudio() }
    let s73 = AVAudioSession.sharedInstance()
    NSLog("[OLCalls] answer action: category=%@ mode=%@ inPage=%d", s73.category.rawValue, s73.mode.rawValue, c.answeredInPage ? 1 : 0)
    action.fulfill()
    if !c.answeredInPage { emit(["type": "answer", "callId": c.callId, "video": c.video]) }
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    traceProviderCallback("end-action", uuid: action.callUUID)
    guard let c = calls[action.callUUID] else { action.fulfill(); return }
    c.ended = true
    stopTimers(c)
    removeCanonicalIdentity(c)
    calls[action.callUUID] = nil
    pageMuted = nil; pendingPageMutes = [] // FX-063: no stale mute echo leaks into the next call's start
    if c.incoming && !c.answered {
      declineOnServer(c.callId, declineToken: c.declineToken)
      c.declineToken = nil // single-use
      emit(["type": "decline", "callId": c.callId])
    } else {
      emit(["type": "hangup", "callId": c.callId])
    }
    action.fulfill()
    resetAudioState("end-action")
    restoreAudioIfIdle()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    traceProviderCallback("mute-action", uuid: action.callUUID)
    action.fulfill()
    if let i = pendingPageMutes.firstIndex(of: action.isMuted) { pendingPageMutes.removeSubrange(0...i); return } // echo of a page tap
    if pageMuted == action.isMuted { return } // already the page's state
    pageMuted = action.isMuted
    emit(["type": "mute", "muted": action.isMuted])
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    traceProviderCallback("start-action", uuid: action.callUUID)
    guard let c = calls[action.callUUID] else { action.fail(); return }
    callVideo = c.video
    configureAudio()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    traceProviderCallback("hold-action", uuid: action.callUUID)
    action.fail() // holding isn't supported
  }

  public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    traceProviderCallback("timed-out-action", uuid: action.uuid)
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    traceProviderCallback("did-activate")
    callKitAudioActive = true
    let incomingCallIsLive = calls.values.contains { !$0.ended && $0.incoming }
    if !incomingCallIsLive { configureAudio() }
    NSLog("[OLCalls] CallKit didActivate: category=%@ mode=%@ nativeAudioOn=%d", audioSession.category.rawValue, audioSession.mode.rawValue, nativeAudioOn ? 1 : 0)
    // Ungranted video calls retain the established WKWebView-media behavior, so their native WebRTC audio unit must
    // remain off. The explicit native-video caller marker is the sole video exception: its one app-owned mic+camera
    // connection must be enabled only after CallKit has handed over the videoChat session. Audio-only native calls
    // remain unchanged.
    let nativeVideo = calls.values.contains(where: { !$0.ended && $0.nativeMedia })
    // b80: Android → iPhone incoming audio (identity from callerPlatform=android at ring time) is native-only, and
    // THIS is its only audio start: playAndRecord/voiceChat/speaker+Bluetooth → setActive → RTCAudioSession
    // didActivate + isAudioEnabled → local+remote audio tracks on. No other path, timer or socket event starts it.
    if calls.values.contains(where: { !$0.ended && $0.incoming && OLNativeAudioLane.isAndroidCall($0.callId) }) {
      nativeAudioOn = true
      OLNativeAudio.laneActivate(audioSession)
      OLNativeAudioLane.callKitActivated()
      OLNativeAudioLane.live?.resumeAudioTracks()
      NSLog("[OLCalls] b80 android lane audio started in didActivate (lane=%d)", OLNativeAudioLane.live == nil ? 0 : 1)
    } else {
      // b74: skip only when the unit is REALLY on for a live call; the flag alone went stale across rapid redials
      // (Keiko → iPhone 2nd/3rd call within ~40 s: packets in, nothing played, mic never started)
      if (!callVideo || nativeVideo) && !(nativeAudioOn && OLNativeAudio.isEnabled && hasLiveCall) {
        nativeAudioOn = true
        OLNativeAudio.didActivate(audioSession, video: nativeVideo)
      }
    }
    // outgoing call still waiting for the callee: ring back natively on the CallKit session (survives the session swap
    // that left WKWebView's <audio>/AudioContext "playing" but silent)
    if calls.values.contains(where: { !$0.incoming && !$0.ended && !$0.answered && !$0.connected }) { startRingback() }
    // Incoming audio never wakes WebKit. The existing page-audio notifications remain only for
    // untouched outgoing behavior.
    if !incomingCallIsLive {
      emit(["type": "audio", "reason": "callkit-activate"])
      for delay in [0.35, 1.2] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          guard let self = self, self.hasLiveCall else { return }
          self.emit(["type": "audio", "reason": "callkit-activate-settle"])
        }
      }
    }
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    OLNativeAudioLane.callKitDeactivated()
    traceProviderCallback("did-deactivate")
    // b74: a late didDeactivate after resetAudioState() already ran is a no-op for our state (only WebRTC's session
    // bookkeeping is told); a new call's flags are never touched by the previous call's deactivation
    if !hasLiveCall && !callKitAudioActive && !nativeAudioOn {
      NSLog("[OLCalls] CallKit didDeactivate (late, already reset): no-op")
      OLNativeAudio.didDeactivate(audioSession)
      return
    }
    callKitAudioActive = false
    nativeAudioOn = false
    NSLog("[OLCalls] CallKit didDeactivate audio session")
    OLNativeAudio.didDeactivate(audioSession)
  }

  /// b74: the single call-end reset (local/remote hangup, timeout, decline, cancel, error, provider reset). Runs even
  /// when didDeactivate never arrives, so the next call's didActivate always enables the unit.
  private func resetAudioState(_ why: String) {
    guard !hasLiveCall else { return }
    NSLog("[OLCalls] b74 resetAudioState(%@): nativeAudioOn=%d callKitAudioActive=%d unit=%d", why, nativeAudioOn ? 1 : 0, callKitAudioActive ? 1 : 0, OLNativeAudio.isEnabled ? 1 : 0)
    nativeAudioOn = false
    callKitAudioActive = false
    stopRingback() // b74: ring/ringback never outlives the call (answer, cancel, end all land here or in stopRingback)
    OLNativeAudio.stopIdle()
  }

  /// b74: safety net (call:connected) and the optional server nudge (call:audioRecover). Audio calls only: a live
  /// CallKit call with an active session but the unit off → enable it once and log it. Transport is never touched.
  private func ensureAudioEnabled(_ why: String) {
    guard let current = calls.values.first(where: { !$0.ended }), !current.incoming,
          !callVideo, callKitAudioActive, !OLNativeAudio.isEnabled else { return }
    NSLog("[OLCalls] b74 force-enable native audio (%@): nativeAudioOn=%d (stale flag / missed didActivate)", why, nativeAudioOn ? 1 : 0)
    nativeAudioOn = true
    OLNativeAudio.didActivate(AVAudioSession.sharedInstance(), video: false)
    emit(["type": "audio", "reason": "force-enable"])
  }

  // MARK: - page → native (src/calls.ts forwards {type:"call:*"} bridge messages)

  func handlePage(_ json: String) {
    guard let data = json.data(using: .utf8),
          let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let type = m["type"] as? String else { return }
    let callId = (m["callId"] as? String) ?? ""
    switch type {
    case "call:incoming":
      let video = (m["video"] as? Bool) ?? false
      var name = String(((m["name"] as? String) ?? "").prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty { name = "Open Lounge" }
      var incoming: [String: String] = ["type": "call_incoming", "callId": callId, "callerName": name, "video": video ? "1" : "0"]
      if let ms = m["expiresAt"] as? Double { incoming["expiresAt"] = String(Int(ms)) }
      if let ms = m["expiresAt"] as? Int { incoming["expiresAt"] = String(ms) }
      if let p = m["callerPlatform"] as? String { incoming["callerPlatform"] = p }
      // Page/WS is a fallback ingress only. It shares the same CallSession/UUID as PushKit.
      handleIncoming(incoming, completion: {})

    case "call:ringtonePrepare":
      // CallKit owns the incoming ringtone/session. Retain b74 reset semantics but do not activate
      // or configure AVAudioSession from the WebView path.
      resetAudioState("ringtone-prepare") // b74: no-op while a call is live
      NSLog("[OLCalls] incoming ringtone preparation deferred to CallKit")

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

    case "call:answering":
      // build 72: Accept tapped on the page's ring screen. Answer the CallKit call NOW (stops the system ring at the tap,
      // activates the session the same way the CallKit answer path does) instead of at call:connected, which waited for
      // media (~1.5–12 s) and let CallKit ring over the live call.
      guard Self.valid(callId) else { return }
      markAnsweredHere(callId)
      if let c = call(callId), c.incoming, !c.answered, !c.ended {
        c.answeredInPage = true
        stopRingback()
        // The fallback card and the in-page UI share this one CallKit action. No incoming
        // AVAudioSession activation occurs here; didActivate is the audio boundary.
        controller.request(CXTransaction(action: CXAnswerCallAction(call: c.uuid))) { err in
          if let err = err { NSLog("[OLCalls] b73 in-app CXAnswerCallAction failed: %@", err.localizedDescription) }
        }
      }

    case "call:connected":
      stopRingback()
      let incomingCall = call(callId)?.incoming == true
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
      } else if !hasLiveCall && !callKitAudioActive {
        NSLog("[OLCalls] refusing page-only incoming audio activation without a live CallKit session")
        emit(["type": "callFailure", "callId": callId, "reason": "missing-callkit-session"])
      }
      // ringback player released the session's output: have the page re-check its mic (captured at dial time, before
      // CallKit activated the session — WebKit can leave it muted → the callee hears nothing) and remote audio
      if !incomingCall && hasLiveCall {
        emit(["type": "audio", "reason": "connected"])
        ensureAudioEnabled("connected")
      }
      // session was configured once at CallKit activation; adjusting it again after connect re-ran the voice
      // processing unit mid-call (volume pumping). Only a real device change or a speaker tap touches it now.

    case "call:ended":
      let targets = calls.values.filter { !$0.ended && (callId.isEmpty || $0.callId == callId) }
      for c in targets {
        c.ended = true
        stopTimers(c)
        removeCanonicalIdentity(c)
        calls[c.uuid] = nil
        if (m["reason"] as? String) == "failed" { provider?.reportCall(with: c.uuid, endedAt: Date(), reason: .failed); continue }
        provider?.reportCall(with: c.uuid, endedAt: Date(), reason: .remoteEnded)
      }
      pageMuted = nil
      pendingPageMutes = []
      stopRingback()
      resetAudioState("page-ended")
      restoreAudioIfIdle(force: true)

    case "call:audioRecover":
      // b74 (optional): one-shot server nudge relayed by the page — same path as the call:connected safety net
      ensureAudioEnabled("server-recover")

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
      webOwnsRingback = true
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
      var reason = 0
      if let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt { reason = Int(v) }
      let why = AVAudioSession.RouteChangeReason(rawValue: UInt(reason)) ?? .unknown
      guard Self.isDeviceRouteChange(why) else { return }
      // AirPods in/out, cable in/out: a new situation, so automatic routing takes over again (FaceTime does the same)
      self.userRoute = nil
      if self.savedAudio != nil { self.configureAudio() } else { self.prepareHeadsetSession() }
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
    let s = AVAudioSession.sharedInstance()
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
    let s = AVAudioSession.sharedInstance()
    let builtIn = s.availableInputs?.first { $0.portType == .builtInMic }
    switch pick.kind {
    case "speaker":
      try? s.setPreferredInput(builtIn)
      do { try s.overrideOutputAudioPort(.speaker) } catch { NSLog("[OLCalls] speaker override failed: %@", error.localizedDescription) }
    case "earpiece":
      try? s.overrideOutputAudioPort(.none)
      try? s.setPreferredInput(builtIn)
    default:
      try? s.overrideOutputAudioPort(.none)
      let match = s.availableInputs?.first { Self.routeId(Self.routeKind($0.portType), $0.portName) == pick.id }
        ?? s.availableInputs?.first { Self.routeKind($0.portType) == pick.kind }
      if let match { try? s.setPreferredInput(match) } else { try? s.setPreferredInput(nil) } // output-only (A2DP/wired) = system choice
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
    if let pick = userRoute { applyUserRoute(pick); return }
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
    if let pick = userRoute {
      applyUserRoute(pick)
      reportActualRoute(reason: "override")
      return
    }
    let s = AVAudioSession.sharedInstance()
    let wantSpeaker = speaker && !Self.headsetAttached()
    let onSpeaker = s.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    if wantSpeaker != onSpeaker {
      do { try s.overrideOutputAudioPort(wantSpeaker ? .speaker : .none) }
      catch { NSLog("[OLCalls] speaker override failed: %@", error.localizedDescription) }
    }
    reportActualRoute(reason: "override")
  }

  /// Speaker/Phone button truth: log and tell the page the route iOS actually chose (builtInSpeaker vs builtInReceiver
  /// vs headset), so the button reflects the real output instead of the last tap. Headset routing is untouched.
  private func reportActualRoute(reason: String) {
    let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
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
      // Incoming audio is native-only. The legacy WebView recovery remains for untouched outgoing calls.
      if self.calls.values.contains(where: { !$0.ended && !$0.incoming }) {
        self.emit(["type": "audio", "reason": "interruption-ended"])
      }
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

  private func restoreAudioIfIdle(force: Bool = false) {
    guard !hasLiveCall, let saved = savedAudio else { return }
    savedAudio = nil
    speaker = true
    callVideo = false
    stopRingback()
    pageMuted = nil
    pendingPageMutes = []
    let s = AVAudioSession.sharedInstance()
    try? s.overrideOutputAudioPort(.none)
    try? s.setCategory(saved.0, mode: saved.1, options: saved.2)
    OLNativeAudio.stopIdle()
    nativeAudioOn = false
    prepareHeadsetSession()
    _ = force
  }
}
