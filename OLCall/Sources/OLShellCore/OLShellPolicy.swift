// Small app-shell rules with no UI: App Lock timing, presence visibility, the session's access
// token, foreground push forwarding, and the native call screen's phases.
import Foundation

public enum OLLockPolicy {
    public enum Lock: Equatable { case checking, locked, unlocked }
    public static let lockAfter: TimeInterval = 60

    /// backgroundedAt <= 0 means cold start.
    public static func shouldLock(enabled: Bool, backgroundedAt: TimeInterval, now: TimeInterval, lockAfter: TimeInterval = lockAfter) -> Bool {
        guard enabled else { return false }
        if backgroundedAt <= 0 { return true }
        return now - backgroundedAt > lockAfter
    }

    /// The page reports presence "visible" only while the app is active and App Lock is off screen
    /// (the server rings CallKit / push only when the user is not visible).
    public static func shouldReportVisible(appActive: Bool, lock: Lock) -> Bool { appActive && lock == .unlocked }
}

public enum OLSessionAccess {
    /// {access, accessExp} from the page's opaque session JSON, or nil.
    public static func from(_ json: String?) -> (token: String, exp: Double)? {
        guard let json, let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)).map(OLJSON.init)?.object,
              let a = o["access"]?.string, !a.isEmpty, let exp = o["accessExp"]?.number else { return nil }
        return (a, exp)
    }
}

/// Foreground push data for the page: string fields only, bounded; call pushes stay on CallKit.
public enum OLForegroundPush {
    public static func data(_ raw: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw {
            guard let k = k as? String, let s = v as? String, k.count <= 64, s.count <= 1024 else { continue }
            out[k] = s
        }
        return out
    }

    public static func shouldForward(_ d: [String: String]) -> Bool { d["type"] != "call_incoming" && d["type"] != "call_cancel" }

    /// In-app path of a notification tap ("/messages/u_1"), or nil.
    public static func openPath(_ d: [AnyHashable: Any]) -> String? {
        guard let u = d["url"] as? String, u.hasPrefix("/"), !u.hasPrefix("//"), u.count <= 300 else { return nil }
        return u
    }
}

/// Keeps foreground pushes while the page is not ready; a newer update for the same tag replaces
/// the older one, untagged updates are all kept (at most 20).
public struct OLForegroundPushQueue {
    private var order: [String] = []
    private var items: [String: [String: String]] = [:]
    private var seq = 0
    public init() {}

    public mutating func enqueue(_ d: [String: String]) {
        let key: String
        if let t = d["tag"], !t.isEmpty { key = "tag:\(t)" } else { seq += 1; key = "untagged:\(seq)" }
        order.removeAll { $0 == key }
        order.append(key)
        items[key] = d
        while order.count > 20 { items[order.removeFirst()] = nil }
    }

    public mutating func drain() -> [[String: String]] {
        defer { order = []; items = [:] }
        return order.compactMap { items[$0] }
    }
}

/// The app's own call screen follows the page's call messages.
public enum OLCallPhase: Equatable {
    case calling, connecting, active, ended

    public static func from(_ m: OLPageCallMessage) -> OLCallPhase? {
        switch m {
        case .outgoing: return .calling
        case .answering: return .connecting
        case .connected: return .active
        case .ended: return .ended
        default: return nil
        }
    }

    public func status(seconds: Int) -> String {
        switch self {
        case .calling: return "Calling…"
        case .connecting: return "Connecting…"
        case .active: return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .ended: return "Call ended"
        }
    }
}
