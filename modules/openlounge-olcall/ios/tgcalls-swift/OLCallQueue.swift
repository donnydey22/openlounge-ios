// Serial queue adapter required by OngoingCallThreadLocalContextWebrtc
// (TgVoipWebrtc PublicHeaders: OngoingCallThreadLocalContextQueueWebrtc).
// Every call into the context happens on this queue; the wrapper asserts
// [queue isCurrent] in its initializer and dispatches every tgcalls callback
// (state, signaling data, video state) back onto it.
import Foundation
#if canImport(TgVoipWebrtc)
import TgVoipWebrtc
#endif

public final class OLCallQueue: NSObject, OngoingCallThreadLocalContextQueueWebrtc {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        super.init()
        queue.setSpecific(key: key, value: ())
    }

    public func async(_ f: @escaping () -> Void) { queue.async(execute: f) }

    public func dispatch(_ f: @escaping () -> Void) {
        if isCurrent() { f() } else { queue.async(execute: f) }
    }

    public func isCurrent() -> Bool { DispatchQueue.getSpecific(key: key) != nil }

    public func scheduleBlock(_ f: @escaping () -> Void, after timeout: Double) -> GroupCallDisposable {
        let work = DispatchWorkItem(block: f)
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        return GroupCallDisposable(block: { work.cancel() })
    }
}
