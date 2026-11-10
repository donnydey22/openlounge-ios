// OLCallQueue — the serial queue one call runs on. The engine context is created and used only
// here, and it delivers every engine callback (state, signaling data, video state) back onto it.
import Foundation
import TgVoipWebrtc

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
