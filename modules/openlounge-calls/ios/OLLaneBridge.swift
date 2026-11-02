import Foundation

/// b75: JS relay for the Swift lane's ms:* requests (native → onMsRequest → page socket → msResponse → native).
final class OLLaneBridge {
  static let shared = OLLaneBridge()
  weak var module: OpenLoungeCallsModule?
  private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
  private var seq = 0
  private let lock = NSLock()

  func request(_ event: String, _ data: [String: Any]) async throws -> [String: Any] {
    guard let m = module else { throw NSError(domain: "OLLane", code: 10, userInfo: [NSLocalizedDescriptionKey: "no JS relay"]) }
    let body = String(data: (try? JSONSerialization.data(withJSONObject: data)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    return try await withCheckedThrowingContinuation { c in
      lock.lock(); seq += 1; let id = "sl\(seq)"; pending[id] = c; lock.unlock()
      m.sendEvent("onMsRequest", ["id": id, "event": event, "json": body])
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
        self?.finish(id, ok: false, json: "", error: "\(event) timed out")
      }
    }
  }

  func finish(_ id: String, ok: Bool, json: String, error: String) {
    lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
    guard let c = c else { return }
    if ok {
      let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
      c.resume(returning: obj)
    } else {
      c.resume(throwing: NSError(domain: "OLLane", code: 11, userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "signaling failed" : error]))
    }
  }

  func emitLane(_ d: [String: Any]) { module?.sendEvent("onLaneEvent", d) }
}
