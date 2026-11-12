// OLCallLog — the Open Lounge call log (Donny t5375). iOS twin of Android OlCallLog.kt.
//
// Every call leg's six-state machine (idle, joining, offering, answering, connected, failed) with
// timestamps, a failure tag on every failed transition, and this leg's device / OS / app version /
// media / role. Events are written to an on-disk queue first (Application Support, atomic writes),
// so they survive the app being killed or the phone restarting, then uploaded to the Open Lounge
// backend: POST https://openlounge.app/api/call-log {events, olcallToken?}. Auth is the app session
// bearer when the app supplies one, else the call's own olcall join token (the server accepts it up
// to 7 days past its expiry, for that call only). Server side: server/calls/callLog.ts.
//
// Never recorded: the join token (kept in a local-only "_tok" field for upload auth and stripped
// before sending), keys, signaling blobs, SDP, TURN usernames or passwords.
import Foundation

public enum OLCallLogTags {
    /// Donny's six failure tags.
    public static let failure = ["offer_never_sent", "answer_timeout", "connection_stalled", "ice_failure",
                                 "audio_session_handoff_failure", "turn_relay_failure"]
    /// Not engine failures; kept as their own tags.
    public static let extra = ["permission_denied", "engine_unavailable", "join_rejected", "cancelled"]

    private static func has(_ r: String, _ re: String) -> Bool { r.range(of: re, options: .regularExpression) != nil }

    /// Raw OLCallStates.diagnose() / close reason -> tag. Same table as Android and the server.
    public static func tag(_ raw: String?, turnServers: Int? = nil, relayOnly: Bool = false) -> String {
        let r = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if failure.contains(r) || extra.contains(r) { return r }
        if has(r, "audio[-_ ]?session|audio[-_ ]?open|adm[-_:]|avaudiosession|audio[-_ ]?unit|mic(rophone)?[-_ ]?(open|unavailable)|audio-focus") { return "audio_session_handoff_failure" }
        if has(r, "permission") { return "permission_denied" }
        if has(r, "olcall-unavailable|engine[-_ ]?unavailable|native-create|media_unavailable|olcall_unavailable") { return "engine_unavailable" }
        if has(r, "cancel") { return "cancelled" }
        if has(r, "no[-_ ]?turn|turn[-_ ]?(alloc|relay|cred|auth|fail|401|403|438)|relay[-_ ]?(fail|alloc)|allocation") { return "turn_relay_failure" }
        if has(r, "unauthori[sz]ed|join[-_ ]?rejected|bad[-_ ]?token|server[-_ ]?full|slot taken") { return "join_rejected" }
        if r.hasPrefix("offer-never-sent") || r.hasPrefix("offer-never-arrived") || r.contains("offer_never_sent") { return "offer_never_sent" }
        if r.hasPrefix("answer-never-arrived") || r.hasPrefix("answer-never-sent") || has(r, "answer[-_ ]?time|join-timeout|no[-_ ]?answer") { return "answer_timeout" }
        if has(r, "ice") || has(r, "tg-failed|dtls") {
            if turnServers == 0 || relayOnly { return "turn_relay_failure" }
            return r.hasPrefix("ice-stalled:ws") ? "connection_stalled" : "ice_failure"
        }
        return "connection_stalled"
    }
}

/// JSONL queue on disk. One event per line; bounded; every write is atomic (survives kill / reboot).
public final class OLCallLogQueue {
    private let url: URL
    private let maxEvents: Int
    private let lock = NSLock()

    public init(url: URL, maxEvents: Int = 5000) {
        self.url = url; self.maxEvents = maxEvents
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("olcall-log", isDirectory: true).appendingPathComponent("queue.jsonl")
    }

    public func append(_ events: [[String: Any]]) {
        guard !events.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = readLocked()
        all.append(contentsOf: events)
        if all.count > maxEvents { all = Array(all.suffix(maxEvents)) }
        writeLocked(all)
    }

    public func all() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return readLocked() }
    public var count: Int { all().count }

    public func remove(eventIds: Set<String>) {
        guard !eventIds.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        writeLocked(readLocked().filter { !eventIds.contains(($0["eventId"] as? String) ?? "") })
    }

    private func readLocked() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { line in
            guard let ld = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any]
        }
    }

    private func writeLocked(_ events: [[String: Any]]) {
        let lines = events.compactMap { e -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        #if os(iOS)
        try? body.data(using: .utf8)?.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? body.data(using: .utf8)?.write(to: url, options: [.atomic])
        #endif
    }
}

/// Posts queued events. Removes an event only after a 200 for it (or 401 for a token that can never
/// authenticate again / 400 / 413 malformed, so the queue cannot grow forever). Retries with backoff.
public final class OLCallLogUploader {
    /// (url, bearer, json body, completion(status or -1)).
    public typealias Transport = (URL, String?, Data, @escaping (Int) -> Void) -> Void

    private let queue: OLCallLogQueue
    private let endpoint: () -> URL?
    private let bearer: () -> String?
    private let transport: Transport
    private let work = DispatchQueue(label: "ol.calllog.upload")
    private var backoff: TimeInterval = 0
    private var busy = false

    public init(queue: OLCallLogQueue, endpoint: @escaping () -> URL?, bearer: @escaping () -> String? = { nil },
                transport: @escaping Transport = OLCallLogUploader.urlSessionTransport) {
        self.queue = queue; self.endpoint = endpoint; self.bearer = bearer; self.transport = transport
    }

    public static let urlSessionTransport: Transport = { url, bearer, body, done in
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = bearer { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, resp, err in
            done(err != nil ? -1 : ((resp as? HTTPURLResponse)?.statusCode ?? -1))
        }.resume()
    }

    public func kick() { work.async { self.flush(completion: nil) } }

    /// Uploads everything queued; completion(accepted count). Synchronous transports complete inline (tests).
    public func flush(completion: ((Int) -> Void)?) {
        guard !busy, let url = endpoint() else { completion?(0); return }
        let events = queue.all()
        guard !events.isEmpty else { completion?(0); return }
        busy = true
        let b = bearer()
        var groups: [(String?, [[String: Any]])] = []
        if b != nil { groups = [(nil, events)] } else {
            var byTok: [String: [[String: Any]]] = [:]
            for e in events { if let t = e["_tok"] as? String, !t.isEmpty { byTok[t, default: []].append(e) } }
            groups = byTok.map { ($0.key, $0.value) }
        }
        var batches: [(String?, [[String: Any]])] = []
        for (tok, evs) in groups { stride(from: 0, to: evs.count, by: 200).forEach { batches.append((tok, Array(evs[$0..<min($0 + 200, evs.count)]))) } }
        var accepted = 0, failed = false
        func next(_ i: Int) {
            guard i < batches.count else {
                busy = false
                if failed { retryLater() } else { backoff = 0 }
                completion?(accepted); return
            }
            let (tok, chunk) = batches[i]
            var body: [String: Any] = ["events": chunk.map { e -> [String: Any] in var c = e; c.removeValue(forKey: "_tok"); return c }]
            if b == nil, let t = tok { body["olcallToken"] = t }
            let ids = Set(chunk.compactMap { $0["eventId"] as? String })
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { queue.remove(eventIds: ids); next(i + 1); return }
            transport(url, b, data) { code in
                if code == 200 { self.queue.remove(eventIds: ids); accepted += chunk.count }
                else if (code == 401 && b == nil) || code == 400 || code == 413 { self.queue.remove(eventIds: ids) }
                else { failed = true }
                next(i + 1)
            }
        }
        next(0)
    }

    private func retryLater() {
        backoff = backoff == 0 ? 5 : backoff == 5 ? 30 : backoff == 30 ? 120 : 600
        work.asyncAfter(deadline: .now() + backoff) { self.flush(completion: nil) }
    }
}

/// One leg's recorder, attached to the engine's OLCallStates.
public final class OLCallLog {
    public struct Meta {
        public var callId: String, role: String?, media: String, device: String, os: String
        public var appVersion: String, engine: String, olcallToken: String?
        public var platform = "ios"
        public init(callId: String, role: String?, media: String, device: String, os: String, appVersion: String, engine: String, olcallToken: String?) {
            self.callId = callId; self.role = role; self.media = media; self.device = device; self.os = os
            self.appVersion = appVersion; self.engine = engine; self.olcallToken = olcallToken
        }
    }

    public static let endpoint = URL(string: "https://openlounge.app/api/call-log")!
    /// Process-wide queue + uploader. The app may set `sessionBearer` so uploads use the app session.
    public static var sessionBearer: () -> String? = { nil }
    public static let sharedQueue = OLCallLogQueue(url: OLCallLogQueue.defaultURL())
    public static let sharedUploader = OLCallLogUploader(queue: sharedQueue, endpoint: { OLCallLog.endpoint }, bearer: { OLCallLog.sessionBearer() })

    public private(set) var meta: Meta
    public var turnServers: Int?
    /// Whether the engine is restricted to the TURN relay. Since build 132 it is not: OLTgcallsInstance creates the
    /// engine direct-first (direct host/srflx pairs first, TURN relay only when they fail), the same ICE policy
    /// as Android. The old default (true, from the relay-only engine) made every 132 event say relayOnly: true while
    /// Pion selected a direct pair (1372bded / 72a8f1e3, Nov 12), and would tag a plain ICE failure as a relay failure.
    /// ci/clean-slate.sh keeps this default in step with the engine's ICE switch.
    public var relayOnly = false
    private var audioFailed = false
    private let queue: OLCallLogQueue
    private let uploader: OLCallLogUploader?
    private let nowMs: () -> Int64

    public init(queue: OLCallLogQueue, uploader: OLCallLogUploader?, meta: Meta,
                nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.queue = queue; self.uploader = uploader; self.meta = meta; self.nowMs = nowMs
    }

    /// Recorder for an engine leg from its CallMedia token (role + callId from the token payload).
    public static func forLeg(token: String, appCallId: String, video: Bool, device: String, os: String, engine: String) -> OLCallLog {
        let c = claims(token)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return OLCallLog(queue: sharedQueue, uploader: sharedUploader, meta: Meta(
            callId: c?.callId ?? appCallId, role: c?.role, media: video ? "video" : "audio", device: device, os: os,
            appVersion: "\(v) (\(b))", engine: engine, olcallToken: token.isEmpty ? nil : token))
    }

    private func base(_ kind: String) -> [String: Any] {
        var e: [String: Any] = ["eventId": UUID().uuidString.lowercased(), "callId": meta.callId, "source": "ios", "platform": meta.platform,
                                "device": meta.device, "os": meta.os, "appVersion": meta.appVersion, "engine": meta.engine,
                                "media": meta.media, "kind": kind, "ts": nowMs()]
        if let r = meta.role { e["role"] = r }
        if let t = meta.olcallToken { e["_tok"] = t }
        var x: [String: Any] = [:]
        if let n = turnServers { x["turnServers"] = n }
        x["relayOnly"] = relayOnly
        e["extra"] = x
        return e
    }

    /// One OLCallStates transition. Failed gets its tag in "reason" and the raw diagnosis in "detail".
    @discardableResult
    public func state(from: OLCallStates.State, to: OLCallStates.State, reason: String, tMs: Int64) -> [String: Any] {
        var e = base("state")
        e["from"] = from.rawValue; e["to"] = to.rawValue; e["t"] = tMs
        if to == .failed {
            e["reason"] = audioFailed && !reason.contains("permission") ? "audio_session_handoff_failure" : OLCallLogTags.tag(reason, turnServers: turnServers, relayOnly: relayOnly)
            e["detail"] = reason
        } else { e["reason"] = reason }
        queue.append([e])
        if to == .failed || to == .connected { uploader?.kick() }
        return e
    }

    /// Non-state event (audio session, relay list, end).
    @discardableResult
    public func event(_ name: String, reason: String? = nil, detail: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        if name == "audio_session" && reason == "audio_session_handoff_failure" { audioFailed = true }
        var e = base("event")
        e["event"] = name
        if let r = reason { e["reason"] = r }
        if let d = detail { e["detail"] = String(d.prefix(240)) }
        var x = e["extra"] as? [String: Any] ?? [:]
        for (k, v) in extra { x[k] = v }
        e["extra"] = x
        queue.append([e])
        if name == "ended" { uploader?.kick() }
        return e
    }

    /// The call never reached the engine (permission denied, engine unavailable): idle -> failed.
    public func failedBeforeStart(_ raw: String) {
        var e = base("state")
        e["from"] = "idle"; e["to"] = "failed"; e["t"] = 0; e["reason"] = OLCallLogTags.tag(raw); e["detail"] = raw
        queue.append([e]); uploader?.kick()
    }

    public func attach(_ states: OLCallStates) {
        states.onTransition = { [weak self] f, t, r, ms in self?.state(from: f, to: t, reason: r, tMs: ms) }
    }

    /// callId + role from an olcall token's payload (labels only; the signature is never checked here).
    public static func claims(_ token: String?) -> (callId: String, role: String)? {
        guard let p1 = token?.split(separator: ".").first else { return nil }
        var s = p1.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let c = o["callId"] as? String, let r = o["role"] as? String else { return nil }
        return (c, r)
    }
}
