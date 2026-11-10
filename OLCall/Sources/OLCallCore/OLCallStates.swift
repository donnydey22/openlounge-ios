// OLCallStates — the one place an Open Lounge call changes state, and the one log line for it.
// Same states, transitions, reasons and line format as Android's OlCallStates.kt.
//
// States: idle, joining, offering, answering, connected, failed.
//   idle      -> joining    WebSocket opened, join {token,...} sent
//   joining   -> offering   joined, isOutgoing = true  (this phone's engine sends the first blobs)
//   joining   -> answering  joined, isOutgoing = false (this phone waits for the far side's blobs)
//   offering/answering -> connected   engine reports Established
//   any (not failed) -> failed        reason says WHERE signaling broke
//
// Log line:  olcall state <from> -> <to> reason=<r> t=<ms> call=<id>
//   t = ms since the state machine started; call = olcall callId from "joined" ("-" before it).
//   Reasons are fixed strings or server/close codes only. Never tokens, keys, blobs or TURN credentials.
//
// Failure diagnosis (failed transition reason = "<where>:<cause>"):
//   offer-never-sent      offering, this phone never emitted a blob
//   answer-never-arrived  offering, blobs sent but none ever came back from the far side
//   answer-never-sent / offer-never-arrived   the same two checks seen from the answering phone
//   ice-stalled           blobs went both ways but the engine never reached Established
//   join-never-acked      no "joined" before the failure (token / server / WebSocket problem)
//
// Not thread-safe by itself: the engine uses it only on its call queue (tests use it directly).
import Foundation

public final class OLCallStates {
    public enum State: String { case idle, joining, offering, answering, connected, failed }

    public private(set) var state: State = .idle
    public var callId = ""
    public private(set) var blobsSent = 0
    public private(set) var blobsReceived = 0
    /// Every emitted line, in order (tests / diagnostics).
    public private(set) var lines: [String] = []

    private let nowMs: () -> Int64
    private let sink: (String) -> Void
    private let started: Int64

    public init(nowMs: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
                sink: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.nowMs = nowMs
        self.sink = sink
        started = nowMs()
    }

    public static func line(from: State, to: State, reason: String, ms: Int64, callId: String) -> String {
        "olcall state \(from.rawValue) -> \(to.rawValue) reason=\(reason) t=\(ms) call=\(callId.isEmpty ? "-" : callId)"
    }

    public func blobSent() { blobsSent += 1 }
    public func blobReceived() { blobsReceived += 1 }

    /// The only state setter. Same-state and post-failure transitions are ignored (failed is terminal).
    @discardableResult
    public func setState(_ to: State, reason: String) -> String? {
        if to == state || state == .failed { return nil }
        let l = Self.line(from: state, to: to, reason: reason, ms: nowMs() - started, callId: callId)
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
        case .offering: at = blobsSent == 0 ? "offer-never-sent" : blobsReceived == 0 ? "answer-never-arrived" : "ice-stalled"
        case .answering: at = blobsReceived == 0 ? "offer-never-arrived" : blobsSent == 0 ? "answer-never-sent" : "ice-stalled"
        case .connected, .failed: at = "after-connect"
        }
        return "\(at):\(cause)"
    }

    /// failed with the diagnosed reason (no-op once already failed).
    @discardableResult
    public func fail(_ cause: String) -> String? { setState(.failed, reason: diagnose(cause)) }
}
