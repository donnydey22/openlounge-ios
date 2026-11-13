// OLSignalingResume — when and how fast the phone re-opens its olcall signaling socket after it drops
// mid-call (Wi-Fi <-> cellular), instead of ending a call whose media engine is still alive.
//
// Evidence: call 11c994c9 (Nov 12 2026, iPhone 132 caller -> Android 55): the socket failed at
// 6:18:22.763 PM MST, OLTgcallsEngine ended the call on "ws-failure" and stopped tgcalls; the page's later
// rejoin was refused ("token: expired") and the server closed the leg at ICE-Failed (6:18:50.5 PM).
// tgcalls itself follows network changes (GATHER_CONTINUALLY + regather, NativeNetworkingImpl.cpp) and only
// gives up after 20 s disconnected; the server keeps a dropped connected leg 20 s. So: resume within 18 s.
// Telegram's own clients do the same split: the call instance survives, signaling rides a connection that
// reconnects (VoIPService.onSignalingData -> ConnectionsManager.sendRequest).
import Foundation

public struct OLSignalingResume {
    /// Below the server's 20 s ws-closed grace and tgcalls' 20 s disconnected timeout.
    public static let window: TimeInterval = 18
    /// One attempt that neither connects nor gets "resumed" within this is abandoned and retried.
    public static let attemptTimeout: TimeInterval = 4
    /// Blobs queued while no socket is up (tgcalls candidates during the gap); oldest dropped beyond this.
    public static let maxQueued = 64

    /// Resume only a call that was connected and whose server issued a resume key. Anything else ends as before.
    public static func shouldResume(connected: Bool, hasKey: Bool, ended: Bool) -> Bool {
        connected && hasKey && !ended
    }

    /// 0.25, 0.5, 1, 2, 2, 2 … seconds before attempt n (0-based).
    public static func delay(attempt n: Int) -> TimeInterval {
        min(0.25 * pow(2, Double(max(0, n))), 2)
    }

    public let startedAt: TimeInterval
    public private(set) var attempts = 0
    public init(now: TimeInterval) { startedAt = now }

    /// Next attempt's delay, or nil when the window is spent (then end the call as before: "ws-failure").
    public mutating func next(now: TimeInterval) -> TimeInterval? {
        let d = Self.delay(attempt: attempts)
        guard now + d < startedAt + Self.window else { return nil }
        attempts += 1
        return d
    }
}
