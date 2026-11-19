// BaoTime binding (Donny, Nov 19 2026): every iOS call surface (CallScreen, MiniBar, CallKit) is driven ONLY by the
// call server's seven-state lifecycle (olcall/server/states.go, {t:"call:state"}), the iOS twin of Android's
// NativeCallFlow.kt. Page call:* messages carry metadata only (name, photo, video). The server is the single writer;
// this maps its snapshot to a surface and never advances state itself.
//
//   idle        -> no surface
//   ringing     -> ringing     "Ringing…"
//   answering   -> answering   "Connecting…"
//   joining_url -> joining     "Joining…"   (link door, no Ringing)
//   connecting  -> connecting  "Connecting…"
//   in_room     -> active      timer        (InRoom internally, the active layout on screen)
//   terminal    -> failed (reason failed: failure banner + Call again) or ended (reason text)
import Foundation

public enum OLCallFlow {
    public enum Screen: String, CaseIterable { case ringing, answering, joining, connecting, active, ended, failed }

    /// BaoTime tints, same values as web calls.module.css tint_* and Android NativeCallFlow.Tone (0xRRGGBB).
    public enum Tone: Equatable {
        case initiating, connected, failed, ended
        public var from: UInt32 {
            switch self { case .initiating: return 0x4338CA; case .connected: return 0x0284C7; case .failed: return 0x7F1D1D; case .ended: return 0x1E293B }
        }
        public var to: UInt32 {
            switch self { case .initiating: return 0x7C3AED; case .connected: return 0x059669; case .failed: return 0xB91C1C; case .ended: return 0x334155 }
        }
    }

    public static func screen(for l: OLCallLifecycle) -> Screen? {
        switch l.state {
        case .idle: return nil
        case .ringing: return .ringing
        case .answering: return .answering
        case .joiningUrl: return .joining
        case .connecting: return .connecting
        case .inRoom: return .active
        case .terminal: return l.reason == .failed ? .failed : .ended
        }
    }

    public static func statusText(_ s: Screen?, reason: OLCallLifecycle.Reason? = nil) -> String {
        switch s {
        case .ringing: return "Ringing…"
        case .answering, .connecting: return "Connecting…"
        case .joining: return "Joining…"
        case .failed: return "Call failed"
        case .ended: return endedText(reason)
        case .active, .none: return ""
        }
    }

    public static func endedText(_ r: OLCallLifecycle.Reason?) -> String {
        switch r {
        case .declined: return "Declined"
        case .missed: return "No answer"
        case .expired: return "Link expired"
        case .cancelledByConfig: return "Call cancelled"
        case .failed: return "Call failed"
        case .disconnected, .completed, .none: return "Call ended"
        }
    }

    public static func tone(_ s: Screen?) -> Tone {
        switch s {
        case .active: return .connected
        case .failed: return .failed
        case .ended: return .ended
        default: return .initiating
        }
    }

    /// Avatar rings: slow pulse while ringing, fast while answering / joining / connecting, none otherwise (ms).
    public static func pulseMs(_ s: Screen?) -> Int {
        switch s {
        case .ringing: return 2400
        case .answering, .joining, .connecting: return 1100
        default: return 0
        }
    }

    public static func timer(_ sec: Int) -> String { String(format: "%d:%02d", sec / 60, sec % 60) }

    /// CallKit (the system banner outside the app), from the same frames.
    public enum CallKitAction: Equatable {
        case none
        case startedConnecting
        case connected
        case ended(EndReason)
    }
    /// Mirrors CXCallEndedReason without importing CallKit into the pure core.
    public enum EndReason: Equatable { case failed, remoteEnded, unanswered }

    public static func callKit(for l: OLCallLifecycle) -> CallKitAction {
        switch l.state {
        case .idle, .ringing: return .none
        case .answering, .joiningUrl, .connecting: return .startedConnecting
        case .inRoom: return .connected
        case .terminal:
            switch l.reason {
            case .failed: return .ended(.failed)
            case .missed, .expired: return .ended(.unanswered)
            default: return .ended(.remoteEnded)
            }
        }
    }

    /// Native -> page (Donny t6054u, same as Android NativeCallFlow.pageStateJson): the seven server-frame states
    /// pushed back to the page as openlounge:native-call {type:"call:native-state", callId, state, reason?, seq}.
    /// Idle is never sent; terminal failed is Failed, every other terminal reason is Terminal (reason carried).
    public enum PageState: String, CaseIterable {
        case ringing = "Ringing", answering = "Answering", joiningUrl = "JoiningUrl", connecting = "Connecting"
        case active = "Active", failed = "Failed", terminal = "Terminal"
    }

    public static func pageState(for l: OLCallLifecycle) -> PageState? {
        switch l.state {
        case .idle: return nil
        case .ringing: return .ringing
        case .answering: return .answering
        case .joiningUrl: return .joiningUrl
        case .connecting: return .connecting
        case .inRoom: return .active
        case .terminal: return l.reason == .failed ? .failed : .terminal
        }
    }

    public static func pageDetail(callId: String, _ l: OLCallLifecycle) -> [String: Any]? {
        guard let ps = pageState(for: l), !callId.isEmpty else { return nil }
        var d: [String: Any] = ["type": "call:native-state", "callId": callId, "state": ps.rawValue, "seq": l.seq]
        if let r = l.reason { d["reason"] = r.rawValue }
        return d
    }
}
