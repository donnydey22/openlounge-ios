// OLBreadcrumbs — call timeline events, same schema as Android's OlBreadcrumbs and the olcall
// server. Self-hosted only: POST https://<olcall host>/v1/crumbs. Payloads are never recorded,
// only length + SHA-256 prefix (8 hex). Keys, tokens and TURN credentials never reach this class.
import CryptoKit
import Foundation
import UIKit

public final class OLBreadcrumbs {
    public var callId = "", traceId = "", leg = ""
    private let url: URL
    private let engine: String
    private let q = DispatchQueue(label: "ol.call.crumbs")
    private var pending: [[String: Any]] = []
    private var seq = ["send": 0, "recv": 0, "local": 0]

    public init(crumbURL: URL, engine: String) { url = crumbURL; self.engine = engine }

    /// wss://host/v1/call -> https://host/v1/crumbs (ws -> http for local tests).
    public static func crumbURL(forCallURL callURL: URL) -> URL {
        var c = URLComponents(url: callURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = c.scheme == "ws" ? "http" : "https"
        c.path = "/v1/crumbs"
        c.query = nil
        return c.url ?? callURL
    }

    public static func digest(_ d: Data) -> String {
        String(SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    public func blob(_ direction: String, _ payload: Data) {
        emit(direction, "tg.blob", "signaling", len: payload.count, sha: Self.digest(payload), level: "info")
    }

    public func event(_ category: String, _ message: String, level: String = "info") {
        emit("local", category, message, len: 0, sha: nil, level: level)
    }

    private func emit(_ dir: String, _ cat: String, _ msg: String, len: Int, sha: String?, level: String) {
        let mono = DispatchTime.now().uptimeNanoseconds
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(identifier: "UTC")!,
                                             formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let osVersion = UIDevice.current.systemVersion
        q.async {
            self.seq[dir, default: 0] += 1
            var o: [String: Any] = ["ts": ts, "monoNs": mono, "source": "ios", "callId": self.callId, "traceId": self.traceId,
                                    "leg": self.leg, "seq": self.seq[dir]!, "direction": dir, "category": cat, "message": msg,
                                    "platform": "ios", "device": OLDevice.model, "osVersion": osVersion,
                                    "engine": self.engine, "level": level]
            if let sha { o["len"] = len; o["sha256"] = sha }
            self.pending.append(o)
            if self.pending.count >= 50 || level == "error" { self.flushLocked() }
        }
    }

    public func flush() { q.async { self.flushLocked() } }

    private func flushLocked() {
        guard !pending.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["crumbs": pending]) else { return }
        let batch = pending
        pending.removeAll()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if err != nil || (resp as? HTTPURLResponse)?.statusCode != 204 {
                self.q.async {
                    self.pending.insert(contentsOf: batch, at: 0) // kept for the next flush, bounded
                    if self.pending.count > 2000 { self.pending.removeFirst(self.pending.count - 2000) }
                }
            }
        }.resume()
    }
}

public enum OLDevice {
    /// Hardware model, e.g. "iPhone15,2".
    public static let model: String = {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}
