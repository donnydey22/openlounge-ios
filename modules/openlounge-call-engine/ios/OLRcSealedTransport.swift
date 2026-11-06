// RingRTC session-model signaling (iOS): OLRtcCall's rtc:signal payloads are E2E-sealed with OLX3DH-v1 and sent as
// rc:msg {callId, dev, envs:{peerDev: env}}; inbound rc:msg is opened and fed to OLRtcCall.onSignal. Caller fans out
// to every callee device until one replies, then locks (Signal multi-device). Mirrors web SealedSignaling.ts and
// Android RcSealedTransport.kt. All state on the main queue (OLRtcCall is main-queue only).
import Foundation

public final class OLRcSealedTransport {
  private weak var sig: CallSignalClient?
  public let callId: String
  private let isCaller: Bool
  private let keys: OLRcKeyStore
  private var sessions: [String: OLX3DHSession] = [:]
  private var locked: String?
  private var pending: [([String: Any], CallSignalClient.Reply?)] = []
  private var initDone = false, initFailed: String?, closed = false
  public var onSignal: (([String: Any]) -> Void)?

  public init(_ sig: CallSignalClient, callId: String, isCaller: Bool, keys: OLRcKeyStore = .shared) {
    self.sig = sig; self.callId = callId; self.isCaller = isCaller; self.keys = keys
    if isCaller { fetchKeys(0) } else { initDone = true }
  }

  private func fetchKeys(_ attempt: Int) {
    guard !closed else { return }
    sig?.request("rc:keys:fetch", ["callId": callId], timeout: 15) { [weak self] r in
      DispatchQueue.main.async {
        guard let self, !self.closed else { return }
        if r["error"] as? String == "no_keys", attempt < 20 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.fetchKeys(attempt + 1) }
        } else { self.initiated(r) }
      }
    }
  }

  private func initiated(_ r: [String: Any]) {
    guard !closed else { return }
    defer { initDone = true; flush() }
    guard r["ok"] as? Bool == true, let arr = r["bundles"] as? [[String: Any]], !arr.isEmpty else { initFailed = (r["error"] as? String) ?? "keys_fetch"; return }
    do {
      let me = try keys.identity()
      for j in arr { if let b = OLBundle(j), let s = try? OLX3DHSession.initiate(me, b) { sessions[b.deviceId] = s } else { OLCallDiskLog.shared.mark("rc", "bundle-reject") } }
      if sessions.isEmpty { initFailed = "no_valid_bundle" }
    } catch { initFailed = "identity" }
  }

  private func flush() {
    let p = pending; pending = []
    for (d, cb) in p { send(d, reply: cb) }
  }

  /// Seam for OLRtcCall.send (replaces sig.request("rtc:signal", …)).
  public func send(_ d: [String: Any], reply: CallSignalClient.Reply?) {
    precondition(Thread.isMainThread)
    if closed { return }
    if let f = initFailed { reply?(["ok": false, "error": "rc_\(f)"]); return }
    if !initDone || sessions.isEmpty { pending.append((d, isCaller ? reply : nil)); if !isCaller { reply?(["ok": true]) }; return }
    guard let plain = try? JSONSerialization.data(withJSONObject: d) else { reply?(["ok": false, "error": "bad_request"]); return }
    var envs: [String: Any] = [:]
    for (dev, s) in sessions where locked == nil || dev == locked { if let e = try? s.seal(plain) { envs[dev] = e } }
    sig?.request("rc:msg", ["callId": callId, "dev": keys.deviceId, "envs": envs], reply: reply)
  }

  /// OLCallManager forwards server evt "rc:msg" here (main queue).
  public func onRcMsg(_ m: [String: Any]) {
    guard !closed, m["callId"] as? String == callId, let dev = m["dev"] as? String,
          let env = (m["envs"] as? [String: Any])?[keys.deviceId] as? [String: Any] else { return }
    if let l = locked, l != dev { return }
    if !initDone { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.onRcMsg(m) }; return }
    do {
      var s = sessions[dev]
      if s == nil {
        guard !isCaller, let pre = env["pre"] as? [String: Any], let spkId = (pre["spkId"] as? NSNumber)?.intValue else { return }
        s = try OLX3DHSession.respond(try keys.identity(), spk: try keys.spk(spkId), opk: try keys.takeOpk((pre["opkId"] as? NSNumber)?.intValue), pre: pre)
        sessions[dev] = s
      }
      guard let s, let inner = try JSONSerialization.jsonObject(with: s.open(env)) as? [String: Any] else { return }
      if locked == nil { locked = dev; s.confirmed(); sessions = [dev: s]; flush() }
      onSignal?(inner)
    } catch { OLCallDiskLog.shared.mark("rc", "open-fail \(error)") }
  }

  public func close() { closed = true; sessions = [:]; pending = [] }

  /// Publish this device's bundle (call when the signal socket authenticates).
  public static func publish(_ sig: CallSignalClient, keys: OLRcKeyStore = .shared) {
    DispatchQueue.global(qos: .utility).async {
      guard let p = try? keys.publishable() else { return }
      DispatchQueue.main.async { sig.request("rc:keys:publish", p) { r in if r["ok"] as? Bool != true { OLCallDiskLog.shared.mark("rc", "publish-failed") } } }
    }
  }
}
