// OLMediaReset — when the phone should restart its tgcalls engine mid-call.
//
// Evidence (Nov 13–14 2026): iPhone 136 signaling resume after a Wi-Fi -> cellular
// switch succeeds in about a second, but tgcalls never re-gathers candidates and
// never reports Reconnecting, so media stays dead. Restart the engine for that
// leg (and ask the server to reset only that peer's translator). Same policy on
// Android 59.
import Foundation

public struct OLMediaReset {
    /// No inbound media this long after a signaling resume -> restart the engine.
    public static let silenceAfterResume: TimeInterval = 3
    public static let cooldown: TimeInterval = 3
    /// Dual-connected phones flap Wi-Fi <-> cellular; every flip needs its own restart (Nov 15 night, 138).
    public static let maxPerCall = 30
    /// tgcalls stuck in reconnecting this long mid-call -> restart the engine.
    public static let reconnectingReset: TimeInterval = 4
    /// Debounce for path flips before moving the signaling socket.
    public static let pathSettle: TimeInterval = 1.5

    /// wifi <-> cellular (or wired), not the first path reading and not a drop to "none".
    public static func pathChange(_ from: String, _ to: String) -> Bool {
        from != to && from != "none" && to != "none" && !from.isEmpty && !to.isEmpty
    }

    public static func allowed(connected: Bool, inFlight: Bool, ended: Bool, count: Int,
                               last: TimeInterval?, now: TimeInterval) -> Bool {
        connected && !inFlight && !ended && count < maxPerCall &&
            (last == nil || now - last! >= cooldown)
    }

    public static func shouldResetOnPathChange(from: String?, to: String, connected: Bool,
                                              inFlight: Bool, ended: Bool, count: Int,
                                              last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let from, pathChange(from, to) else { return false }
        return allowed(connected: connected, inFlight: inFlight, ended: ended, count: count, last: last, now: now)
    }

    /// After signaling came back: if media has not started flowing again, restart.
    public static func shouldResetOnSilence(resumedAt: TimeInterval?, flowing: Bool, connected: Bool,
                                           inFlight: Bool, ended: Bool, count: Int,
                                           last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let resumedAt, !flowing, now - resumedAt >= silenceAfterResume else { return false }
        return allowed(connected: connected, inFlight: inFlight, ended: ended, count: count, last: last, now: now)
    }
}
