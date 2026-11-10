// OLCallStates — the one place an olcall call changes state, and the one log line for it.
//
// States (same names as Android): idle, joining, offering, answering, connected, failed.
//   idle      -> joining    WebSocket opened, join {token,...} sent
//   joining   -> offering   joined, isOutgoing = true  (this phone's tgcalls sends the first blobs)
//   joining   -> answering  joined, isOutgoing = false (this phone waits for the far side's blobs)
//   offering/answering -> connected   tgcalls reports Established
//   any (not failed) -> failed        reason says WHERE signaling broke
//
// Log line (identical format to Android):  olcall state <from> -> <to> reason=<r> t=<ms> call=<id>
//   t = ms since the call object started; call = olcall callId from "joined" ("-" before it).
//   Reasons are fixed strings or server/close codes only. Never tokens, keys, blobs or TURN credentials.
//
// Failure diagnosis (failed transition reason = "<where>:<cause>"):
//   offer-never-sent      offering, this phone never emitted a tgcalls blob
//   answer-never-arrived  offering, blobs sent but none ever came back from the far side
//   answer-never-sent / offer-never-arrived   same two checks seen from the answering phone
//   ice-stalled           blobs went both ways but tgcalls never reached Established
//   join-never-acked      no "joined" before the failure (token/server/WebSocket problem)
import Foundation

public final class OLCallStates {
    public enum State: String { case idle, joining, offering, answering, connected, failed }

    public private(set) var state: State = .idle
    public var callId = ""
    public private(set) var blobsSent = 0
    public private(set) var blobsReceived = 0
    /// Every emitted line, in order (tests / diagnostics).
    public private(set) var lines: [String] = []

    private let now: () -> TimeInterval
    private let started: TimeInterval
    private let sink: (String) -> Void

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sink: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.now = now
        self.started = now()
        self.sink = sink
    }

    public static func line(from: State, to: State, reason: String, ms: Int, callId: String) -> String {
        "olcall state \(from.rawValue) -> \(to.rawValue) reason=\(reason) t=\(ms) call=\(callId.isEmpty ? "-" : callId)"
    }

    public func blobSent() { blobsSent += 1 }
    public func blobReceived() { blobsReceived += 1 }

    /// The only state setter. Same-state and post-failure transitions are ignored (failed is terminal).
    @discardableResult
    public func setState(_ to: State, reason: String) -> String? {
        guard to != state, state != .failed else { return nil }
        let ms = Int(((now() - started) * 1000).rounded())
        let l = Self.line(from: state, to: to, reason: reason, ms: ms, callId: callId)
        state = to
        lines.append(l)
        sink(l)
        return l
    }

    /// Where signaling broke, for the failed transition. `cause` = close/server reason (e.g. ws-failure, tg-failed).
    public func diagnose(_ cause: String) -> String {
        let at: String
        switch state {
        case .idle, .joining: at = "join-never-acked"
        case .offering:
            at = blobsSent == 0 ? "offer-never-sent" : blobsReceived == 0 ? "answer-never-arrived" : "ice-stalled"
        case .answering:
            at = blobsReceived == 0 ? "offer-never-arrived" : blobsSent == 0 ? "answer-never-sent" : "ice-stalled"
        case .connected, .failed: at = "after-connect"
        }
        return "\(at):\(cause)"
    }

    /// failed with the diagnosed reason (no-op once connected-and-normal or already failed).
    @discardableResult
    public func fail(_ cause: String) -> String? { setState(.failed, reason: diagnose(cause)) }
}
