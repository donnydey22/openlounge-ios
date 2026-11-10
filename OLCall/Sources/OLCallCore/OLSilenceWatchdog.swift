// OLSilenceWatchdog — "this audio stream has been dead for N seconds" for a connected call.
//
// Fed with a level stream while the call is connected. A live stream is never exactly silent:
// even a quiet room has a noise floor. While `active`, a level at or below `floor` for `window`
// seconds is a dead stream: the first `maxRecoveries` windows each return .recover(attempt), the
// next one returns .reportSilent once. Any audible sample, or going inactive, starts over.
//
// The engine feeds it the far side's audio level (tgcalls audioLevelUpdated is the receive-side
// level; the TgVoipWebrtc API has no level for the audio this phone sends).
import Foundation

public final class OLSilenceWatchdog {
    public enum Action: Equatable { case none, recover(attempt: Int), reportSilent }

    public let window: TimeInterval
    public let floor: Float
    public let maxRecoveries: Int
    private var silentSince: TimeInterval?
    private var recoveries = 0
    private var reported = false

    public init(window: TimeInterval = 6, floor: Float = 0.0001, maxRecoveries: Int = 2) {
        self.window = window; self.floor = floor; self.maxRecoveries = maxRecoveries
    }

    /// One level sample. `active` = connected and the stream is expected to carry audio
    /// (for the far side: not muted).
    public func sample(level: Float, active: Bool, now: TimeInterval) -> Action {
        guard active else { silentSince = nil; return .none }
        if level > floor {
            reset()
            return .none
        }
        guard let since = silentSince else { silentSince = now; return .none }
        guard now - since >= window else { return .none }
        silentSince = now
        if recoveries < maxRecoveries {
            recoveries += 1
            return .recover(attempt: recoveries)
        }
        if reported { return .none }
        reported = true
        return .reportSilent
    }

    public func reset() { silentSince = nil; recoveries = 0; reported = false }
}
