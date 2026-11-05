// Native call signaling on the app's own socket to openlounge.app/ws, in the exact frame format the web client uses
// (openlounge web f22432e src/lib/realtime.ts): request {t:"req",id,ev,data} (:290) -> reply {t:"res",id,data} (:99),
// fire-and-forget {t:"evt",ev,data} (:277), server push {t:"evt",ev,data} (:106). The socket signs in with
// session:resume {token} (server/wsSchemas.ts:23) using the access token the page already mirrors to the Keychain
// (OLCallAuth, src/calls.ts setAuth). Heartbeat = the web's "ping" request every 20 s, 10 s timeout (realtime.ts:10-11).
// Calls: call:start {peerId,video,platform} (:73), call:ack (:74), call:accept {callId} (:75), call:decline (:76),
// call:hangup (:77), ms:join {callId} (:93), ms:plain:* (:102-105).
import Foundation

public final class CallSignalClient: NSObject, URLSessionWebSocketDelegate {
  public typealias Reply = ([String: Any]) -> Void
  /// server push events (call:incoming, call:state, call:video ...); delivered on the main queue
  public var onEvent: ((String, [String: Any]) -> Void)?
  /// socket signed in (true) / lost (false); main queue
  public var onAuthed: ((Bool) -> Void)?
  /// returns a still-valid access token, or nil (then the socket waits for the next token)
  public var tokenProvider: (() -> String?)?
  public private(set) var authed = false

  private let url: URL
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var nextId = 1
  private var pending: [Int: (Reply, Timer)] = [:]
  private var heartbeat: Timer?
  private var retry = 0
  private var reconnectTimer: Timer?
  private var wanted = false
  private var waitingAuth: [() -> Void] = []

  public init(baseURL: URL) {
    var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    c.scheme = c.scheme == "http" ? "ws" : "wss"
    c.path = "/ws"
    c.query = nil
    url = c.url!
  }

  /// Keep the socket up (idempotent). Main queue.
  public func connect() {
    wanted = true
    if task != nil { return }
    guard let token = tokenProvider?(), !token.isEmpty else { return } // no session yet: setAuth calls connect() again
    let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    session = s
    let t = s.webSocketTask(with: url)
    t.maximumMessageSize = 2_000_000
    task = t
    t.resume()
    receive(t)
    sendFrame(["t": "req", "id": takeId(registering: { [weak self] r in self?.resumed(r) }, timeout: 10), "ev": "session:resume", "data": ["token": token]], on: t)
  }

  public func close() {
    wanted = false
    drop(reconnect: false)
  }

  /// Run `fn` once the socket is signed in (connects if needed).
  public func whenAuthed(_ fn: @escaping () -> Void) {
    if authed { fn(); return }
    waitingAuth.append(fn)
    connect()
  }

  /// request/response; `reply` gets the server's data, or {ok:false,error} on timeout / socket loss. Main queue.
  public func request(_ ev: String, _ data: [String: Any], timeout: TimeInterval = 10, reply: Reply? = nil) {
    // registered now so a socket that never signs in still answers (timeout), sent once signed in
    let id = takeId(registering: reply ?? { _ in }, timeout: timeout + (authed ? 0 : 10))
    whenAuthed { [weak self] in
      guard let self, self.pending[id] != nil, let t = self.task else { return }
      self.sendFrame(["t": "req", "id": id, "ev": ev, "data": data], on: t)
    }
  }

  public func emit(_ ev: String, _ data: [String: Any]) {
    guard authed, let t = task else { return }
    sendFrame(["t": "evt", "ev": ev, "data": data], on: t)
  }

  // MARK: calls (server/wsSchemas.ts)
  public func start(peerId: String, video: Bool, reply: @escaping Reply) { request("call:start", ["peerId": peerId, "video": video, "platform": "ios"], reply: reply) }
  public func ack(_ callId: String) { request("call:ack", ["callId": callId]) }
  public func accept(_ callId: String, reply: @escaping Reply) { request("call:accept", ["callId": callId, "platform": "ios"], reply: reply) }
  public func decline(_ callId: String, reply: Reply? = nil) { request("call:decline", ["callId": callId], reply: reply) }
  public func hangup(_ callId: String, reply: Reply? = nil) { request("call:hangup", ["callId": callId], reply: reply) }

  // MARK: private
  private func takeId(registering r: @escaping Reply, timeout: TimeInterval) -> Int {
    let id = nextId; nextId += 1
    let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
      guard let self, let p = self.pending.removeValue(forKey: id) else { return }
      p.0(["ok": false, "error": "Request timed out"])
    }
    pending[id] = (r, timer)
    return id
  }

  private func sendFrame(_ m: [String: Any], on t: URLSessionWebSocketTask) {
    guard let d = try? JSONSerialization.data(withJSONObject: m), let s = String(data: d, encoding: .utf8) else { return }
    t.send(.string(s)) { _ in }
  }

  private func resumed(_ r: [String: Any]) {
    guard (r["ok"] as? Bool) == true else {
      NSLog("[OLSignal] session:resume refused (%@)", (r["reason"] as? String) ?? "?")
      drop(reconnect: false) // expired/invalid: wait for the page's next token (setAuth -> connect)
      return
    }
    authed = true
    retry = 0
    startHeartbeat()
    onAuthed?(true)
    let w = waitingAuth; waitingAuth = []
    w.forEach { $0() }
  }

  private func receive(_ t: URLSessionWebSocketTask) {
    t.receive { [weak self] r in
      DispatchQueue.main.async {
        guard let self, self.task === t else { return }
        switch r {
        case .failure: self.drop(reconnect: true)
        case .success(let msg):
          var text: String?
          if case .string(let s) = msg { text = s } else if case .data(let d) = msg { text = String(data: d, encoding: .utf8) }
          if let s = text, let d = s.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            if m["t"] as? String == "res", let id = (m["id"] as? NSNumber)?.intValue, let p = self.pending.removeValue(forKey: id) {
              p.1.invalidate(); p.0((m["data"] as? [String: Any]) ?? [:])
            } else if m["t"] as? String == "evt", let ev = m["ev"] as? String {
              self.onEvent?(ev, (m["data"] as? [String: Any]) ?? [:])
            }
          }
          self.receive(t)
        }
      }
    }
  }

  private func startHeartbeat() {
    heartbeat?.invalidate()
    heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      guard let self, let t = self.task else { return }
      let id = self.takeId(registering: { [weak self] r in if r["error"] as? String == "Request timed out" { self?.drop(reconnect: true) } }, timeout: 10)
      self.sendFrame(["t": "req", "id": id, "ev": "ping", "data": [:]], on: t)
    }
  }

  private func drop(reconnect: Bool) {
    let was = authed
    authed = false
    heartbeat?.invalidate(); heartbeat = nil
    task?.cancel(with: .normalClosure, reason: nil); task = nil
    session?.invalidateAndCancel(); session = nil
    let p = pending; pending = [:]
    for (_, v) in p { v.1.invalidate(); v.0(["ok": false, "error": "Connection lost"]) }
    if was { onAuthed?(false) }
    guard reconnect, wanted else { return }
    // web backoff (realtime.ts scheduleReconnect): ~0.2 s, then 0.5, 1, 2 ... capped at 1 s in a call / 10 s otherwise
    let n = retry; retry += 1
    let base = n == 0 ? 0.2 : min(10, 0.5 * pow(2, Double(n - 1)))
    reconnectTimer?.invalidate()
    reconnectTimer = Timer.scheduledTimer(withTimeInterval: base * Double.random(in: 0.75...1.25), repeats: false) { [weak self] _ in self?.connect() }
  }

  /// Network came back / app foregrounded: reconnect now instead of waiting out the backoff.
  public func kick() { if wanted && task == nil { reconnectTimer?.invalidate(); retry = 0; connect() } }

  public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    if webSocketTask === task { drop(reconnect: true) }
  }
}
