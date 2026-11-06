// Sole AVAudioSession owner for Open Lounge calling. Signal-iOS behavior oracle
// (Signal/Calls/AudioSession+WebRTC.swift): WebRTC manual audio, CallKit didActivate/didDeactivate forwarded to
// RTCAudioSession, audio enabled only after activation. No RingRTC/Signal code copied (AGPL) — behavior only.
//
// CI gate (scripts/check-audio-session-owner.sh): this is the ONLY file that may touch AVAudioSession.
// Rules enforced here:
//  * serialized: every entry point runs on the main queue (one owner, one order of events)
//  * configure exactly once per call BEFORE CallKit activation; configuration errors propagate (no try? swallow)
//  * the OS activation callback (CallKit didActivate) is authoritative; this owner never fakes it, never uses
//    isOtherAudioPlaying as an "is active" test, and never copies/reapplies the category mid-call
//  * a call-scoped readiness lease: media (OLCallAudioEngine) waits on `whenActive` and starts only after
//    didActivate → RTCAudioSession.audioSessionDidActivate; bounded timeout = explicit failure, never silent
//  * didDeactivate suspends (generation bump) WITHOUT discarding the call holder; resumes on the next didActivate
//  * rooms / voice notes / ambient can never displace a live call holder
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif

public enum OLAudioHolderKind: Equatable { case call, room, voiceNote, ambient }

public struct OLAudioHolderToken: Hashable { fileprivate let id: UInt64 }

public enum OLAudioSessionError: Error, CustomStringConvertible {
  case notMainThread, noCallHolder, configureFailed(String), activationTimeout(generation: UInt64), deactivated, ended
  public var description: String {
    switch self {
    case .notMainThread: return "owner entry off main"
    case .noCallHolder: return "no call holder"
    case .configureFailed(let e): return "configure failed: \(e)"
    case .activationTimeout(let g): return "CallKit didActivate not received (gen \(g))"
    case .deactivated: return "session deactivated"
    case .ended: return "call ended"
    }
  }
}

public enum OLAudioSessionState: Equatable { case idle, configured, active(generation: UInt64), suspended(generation: UInt64) }

public final class OLAudioSessionOwner {
  public static let shared = OLAudioSessionOwner()

  private struct Entry { let token: OLAudioHolderToken; let kind: OLAudioHolderKind }
  private var stack: [Entry] = []
  private var nextId: UInt64 = 1
  private var callToken: OLAudioHolderToken?
  public private(set) var state: OLAudioSessionState = .idle
  private var generation: UInt64 = 0
  private var waiters: [(id: UInt64, cb: (Result<UInt64, OLAudioSessionError>) -> Void)] = []
  private var nextWaiter: UInt64 = 1
  /// Observers (OLCallAudioEngine) told on activate/deactivate in the same serialized order.
  public var onActivated: ((UInt64) -> Void)?
  public var onDeactivated: ((UInt64) -> Void)?

  private init() {
    #if canImport(WebRTC)
    // Signal: manual audio — WebRTC must NOT start the AudioUnit until CallKit activation is forwarded.
    let rtc = RTCAudioSession.sharedInstance()
    rtc.useManualAudio = true
    rtc.isAudioEnabled = false
    #endif
  }

  // MARK: holders
  @discardableResult
  public func push(_ kind: OLAudioHolderKind) -> OLAudioHolderToken? {
    precondition(Thread.isMainThread)
    if kind != .call, callToken != nil {
      NSLog("[OLAudio] refuse push %@ while call held", String(describing: kind)); return nil
    }
    if kind == .call, callToken != nil { return callToken } // one call holder; idempotent
    let tok = OLAudioHolderToken(id: nextId); nextId += 1
    stack.append(Entry(token: tok, kind: kind))
    if kind == .call { callToken = tok }
    return tok
  }

  public func pop(_ token: OLAudioHolderToken?) {
    precondition(Thread.isMainThread)
    guard let token else { return }
    stack.removeAll { $0.token == token }
    if callToken == token { callToken = nil; endCall() }
  }

  public var hasCallHolder: Bool { callToken != nil }

  // MARK: call lifecycle (configure → [CallKit fulfills action] → didActivate → lease resolves → engine enables audio)

  /// Configure playAndRecord/voiceChat BEFORE the CallKit action is fulfilled. Never setActive (CallKit activates).
  /// Idempotent within a call: a second call while configured/active is a no-op (no mid-call category copy).
  public func configureForCall() throws {
    precondition(Thread.isMainThread)
    guard callToken != nil else { throw OLAudioSessionError.noCallHolder }
    guard state == .idle else { return }
    let s = AVAudioSession.sharedInstance()
    do {
      // Signal/Linphone call mode: playAndRecord + voiceChat, HFP allowed; no mixWithOthers / A2DP / defaultToSpeaker.
      try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
    } catch { throw OLAudioSessionError.configureFailed(error.localizedDescription) }
    // Preferences are requests; the negotiated hardware rate is read after activation and WebRTC resamples.
    // Not forced to 48 kHz (HFP runs 8/16 kHz). Failure here is logged, not fatal: the OS may refuse a preference.
    do { try s.setPreferredIOBufferDuration(0.02) } catch { NSLog("[OLAudio] buffer pref refused: %@", error.localizedDescription) }
    state = .configured
  }

  /// CallKit provider(_:didActivate:). The only activation path for calls.
  public func callKitDidActivate(_ session: AVAudioSession) {
    precondition(Thread.isMainThread)
    generation &+= 1
    let g = generation
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().audioSessionDidActivate(session)
    #endif
    guard callToken != nil else { NSLog("[OLAudio] didActivate without call holder (gen %llu)", g); return }
    state = .active(generation: g)
    NSLog("[OLAudio] active gen=%llu rate=%.0f io=%.4f route=%@", g, session.sampleRate, session.ioBufferDuration,
          session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))
    let w = waiters; waiters = []
    w.forEach { $0.cb(.success(g)) }
    onActivated?(g)
  }

  /// CallKit provider(_:didDeactivate:). Suspends media; the call holder is kept (resume on next didActivate).
  public func callKitDidDeactivate(_ session: AVAudioSession) {
    precondition(Thread.isMainThread)
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().audioSessionDidDeactivate(session)
    #endif
    let g = generation
    if callToken != nil { state = .suspended(generation: g) } else { state = .idle }
    onDeactivated?(g)
  }

  public var isActive: Bool { if case .active = state { return true }; return false }

  /// Readiness lease: resolves with the activation generation once didActivate has been forwarded.
  /// Already active → resolves immediately. Timeout → explicit `.activationTimeout` (caller fails the call visibly).
  public func whenActive(timeout: TimeInterval = 8, _ cb: @escaping (Result<UInt64, OLAudioSessionError>) -> Void) {
    precondition(Thread.isMainThread)
    guard callToken != nil else { return cb(.failure(.noCallHolder)) }
    if case .active(let g) = state { return cb(.success(g)) }
    let id = nextWaiter; nextWaiter += 1
    waiters.append((id, cb))
    let g = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard let self, let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
      let w = self.waiters.remove(at: i)
      w.cb(.failure(.activationTimeout(generation: g)))
    }
  }

  private func endCall() {
    let w = waiters; waiters = []
    w.forEach { $0.cb(.failure(.ended)) }
    state = .idle
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    #endif
  }

  /// Media services reset: OS discarded session config. Re-configure once (same call), then the engine reopens once
  /// on the next activation. Never setActive here; CallKit remains the activation authority.
  public func mediaServicesReset() throws {
    precondition(Thread.isMainThread)
    guard callToken != nil else { return }
    state = .idle
    try configureForCall()
  }

  // MARK: routes (post-activation only)
  public func applyRoute(speakerWanted: Bool, headsetAttached: Bool) {
    precondition(Thread.isMainThread)
    guard isActive else { return } // pre-activation overrides fail; reapplied on didActivate by OLCallManager
    let s = AVAudioSession.sharedInstance()
    let wantSpeaker = speakerWanted && !headsetAttached
    let onSpeaker = s.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    guard wantSpeaker != onSpeaker else { return }
    do { try s.overrideOutputAudioPort(wantSpeaker ? .speaker : .none) }
    catch { NSLog("[OLAudio] route override failed: %@", error.localizedDescription) }
  }

  public var currentRoute: AVAudioSessionRouteDescription { AVAudioSession.sharedInstance().currentRoute }
  public var availableInputs: [AVAudioSessionPortDescription]? { AVAudioSession.sharedInstance().availableInputs }

  /// Explicit user route pick from the call screen. Speaker overrides any headset; Phone selects the built-in mic
  /// (output follows to receiver); a headset pick selects that headset's input.
  public func applyUserRoute(kind: String, id: String, idOf: (AVAudioSessionPortDescription) -> String, kindOf: (AVAudioSessionPortDescription) -> String) {
    precondition(Thread.isMainThread)
    let s = AVAudioSession.sharedInstance()
    let builtIn = s.availableInputs?.first { $0.portType == .builtInMic }
    do {
      switch kind {
      case "speaker":
        try s.setPreferredInput(builtIn); try s.overrideOutputAudioPort(.speaker)
      case "earpiece":
        try s.overrideOutputAudioPort(.none); try s.setPreferredInput(builtIn)
      default:
        try s.overrideOutputAudioPort(.none)
        let match = s.availableInputs?.first { idOf($0) == id } ?? s.availableInputs?.first { kindOf($0) == kind }
        try s.setPreferredInput(match) // nil = output-only device (A2DP/wired) → system choice
      }
    } catch { NSLog("[OLAudio] user route %@ failed: %@", kind, error.localizedDescription) }
  }
}
