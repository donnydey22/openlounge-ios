// The server-owned call lifecycle (olcall/server/states.go), as received in {t:"call:state", lifecycle:{...}}.
//
// Single-writer: the olcall server is the only writer of this state. The phone never computes, advances or
// caches its own copy; it holds the latest snapshot the server sent and nothing else. Wire values are pinned
// to Go (and Android's OlCallLifecycle.kt) by the shared golden fixture Fixtures/lifecycle.json.
import Foundation

public struct OLCallLifecycle: Equatable {
    /// BaoTime CallLifecycle's seven states, in lifecycle order. Raw values match Go's CallState.String().
    public enum State: String, CaseIterable {
        case idle, ringing, answering
        case joiningUrl = "joining_url"
        case connecting
        case inRoom = "in_room"
        case terminal
    }

    public enum Reason: String, CaseIterable {
        case declined, missed, disconnected, expired
        case cancelledByConfig = "cancelled_by_config"
        case failed, completed
    }

    public let callId: String
    public let leg: String
    public let state: State
    /// Non-nil only in `.terminal`.
    public let reason: Reason?
    public let seq: Int64
    public let event: String

    /// Parses the "lifecycle" object of a call:state frame; nil if it is not a valid snapshot.
    public static func parse(_ o: [String: Any]?) -> OLCallLifecycle? {
        guard let o, let s = o["state"] as? String, let state = State(rawValue: s) else { return nil }
        var reason: Reason?
        if let r = o["reason"] as? String, !r.isEmpty {
            guard let rr = Reason(rawValue: r) else { return nil }
            reason = rr
        }
        guard (state == .terminal) == (reason != nil) else { return nil }
        guard let n = o["seq"] as? NSNumber, n.int64Value >= 1 else { return nil }
        return OLCallLifecycle(callId: o["callId"] as? String ?? "", leg: o["leg"] as? String ?? "", state: state,
                               reason: reason, seq: n.int64Value, event: o["event"] as? String ?? "")
    }

    /// Observer rule: take the server's snapshot only if it is newer than the one held (seq order).
    public static func newer(_ held: OLCallLifecycle?, _ incoming: OLCallLifecycle) -> Bool {
        guard let held else { return true }
        return incoming.seq > held.seq
    }
}
