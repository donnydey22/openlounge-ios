// RingRTC CallManager session model (2.74.0 CallState / CallEvent / HangupType), iOS. One active call; second → busy.
// OLCallManager (CallKit) drives it; media = OLRtcCall (BSD WebRTC M152, manual audio via OLAudioSessionOwner).
import Foundation

public enum OLRcCallState: String { case idle, starting, ringing, connecting, connected, reconnecting, ended }
public enum OLRcHangup: String { case normal, accepted, declined, busy, needPermission, timeout, failed }
public enum OLRcCallEvent: String { case localRinging, remoteRinging, localConnected, reconnecting, reconnected, localHangup, remoteHangup, remoteBusy, endedTimeout, endedConnectionFailure, endedDeviceFailure, endedSignalingFailure }

public final class OLRcCallManager {
  public static let shared = OLRcCallManager()
  public static let ringTimeout: TimeInterval = 60
  public private(set) var callId: String?
  public private(set) var state: OLRcCallState = .idle
  public var onState: ((String, OLRcCallState, OLRcCallEvent?) -> Void)?
  public var onEnded: ((String, OLRcHangup) -> Void)?

  /// false = busy (RingRTC auto-busy for a second call)
  @discardableResult public func begin(_ id: String, outgoing: Bool) -> Bool {
    if let c = callId, c != id, state != .ended, state != .idle { return false }
    callId = id; move(outgoing ? .starting : .ringing, outgoing ? .remoteRinging : .localRinging); return true
  }
  public func connecting(_ id: String) { if id == callId { move(.connecting, nil) } }
  public func connected(_ id: String) { if id == callId { move(.connected, state == .reconnecting ? .reconnected : .localConnected) } }
  public func reconnecting(_ id: String) { if id == callId, state == .connected { move(.reconnecting, .reconnecting) } }
  public func end(_ id: String, _ h: OLRcHangup, _ ev: OLRcCallEvent) {
    guard id == callId, state != .ended else { return }
    move(.ended, ev); onEnded?(id, h); callId = nil; state = .idle
  }
  private func move(_ s: OLRcCallState, _ ev: OLRcCallEvent?) { state = s; if let c = callId { onState?(c, s, ev) }; OLCallDiskLog.shared.mark("rc-state", "\(s.rawValue) \(ev?.rawValue ?? "")") }
}
