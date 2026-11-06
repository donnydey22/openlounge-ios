// OLCallAudioEngine — the one call audio engine on iOS (replaces the removed SIP-engine sound open + media
// orchestration). WebRTC (signalapp/webrtc 8037b-equivalent build, BSD) in MANUAL AUDIO mode, Signal-iOS behavior:
//   CallKit fulfill → didActivate → OLAudioSessionOwner forwards to RTCAudioSession → owner lease resolves →
//   this engine sets RTCAudioSession.isAudioEnabled = true → ADM starts capture/playout.
// Never touches AVAudioSession (CI gate). Never fakes activation. Local audio failure is a typed LOCAL error and
// must never be routed into TURN/relay fallback (network errors only).
import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

public enum OLCallAudioError: Error, CustomStringConvertible {
  case activation(String)   // owner lease failed / timed out — local, not network
  case deviceStart(String)  // ADM did not start — local
  case ended
  public var isNetwork: Bool { false } // audio-path errors are never network errors
  public var description: String {
    switch self { case .activation(let s): return "audio-activation: \(s)"; case .deviceStart(let s): return "audio-device: \(s)"; case .ended: return "ended" }
  }
}

public final class OLCallAudioEngine {
  public static let shared = OLCallAudioEngine()

  public enum Phase: Equatable { case idle, waitingActivation, running(generation: UInt64), suspended, failed(String) }
  public private(set) var phase: Phase = .idle
  private var callId: String?
  private var wantMedia = false
  public var onPhase: ((Phase) -> Void)?
  public private(set) var muted = false

  #if canImport(WebRTC)
  /// One factory for the process; peer connections for calls are created from this (manual audio already set by owner).
  public lazy var factory: RTCPeerConnectionFactory = {
    RTCInitializeSSL()
    return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
  }()
  private var audioTrack: RTCAudioTrack?
  #endif

  /// New call (CXStart / CXAnswer). Resets per-call state; audio stays disabled until activation.
  public func prepare(callId: String) {
    precondition(Thread.isMainThread)
    stopAudio()
    self.callId = callId; wantMedia = false; muted = false
    set(.waitingActivation)
    OLCallDiskLog.shared.mark("audio-engine", "prepare")
  }

  /// Signaling permission granted (callee accepted / caller got answer). Starts media only once the owner's lease
  /// has resolved; `lease` is OLAudioSessionOwner.whenActive (passed in so this module never imports the owner).
  public func startMedia(lease: (@escaping (Result<UInt64, Error>) -> Void) -> Void, done: @escaping (Result<Void, OLCallAudioError>) -> Void) {
    precondition(Thread.isMainThread)
    guard let id = callId else { return done(.failure(.ended)) }
    wantMedia = true
    lease { [weak self] r in
      guard let self, self.callId == id else { return done(.failure(.ended)) }
      switch r {
      case .failure(let e):
        self.set(.failed("\(e)")); OLCallDiskLog.shared.mark("audio-engine", "activation-failed \(e)")
        done(.failure(.activation("\(e)")))
      case .success(let g):
        self.enableAudio(generation: g)
        if case .running = self.phase { done(.success(())) } else { done(.failure(.deviceStart("audio not running"))) }
      }
    }
  }

  /// Called by OLCallManager from OLAudioSessionOwner.onActivated.
  public func sessionActivated(_ g: UInt64) {
    guard callId != nil else { return }
    if wantMedia { enableAudio(generation: g) } // resume after interruption / reset: reopen exactly once per gen
  }

  /// didDeactivate: suspend capture/playout, keep call + holder + tracks (Signal: isAudioEnabled = false).
  public func sessionDeactivated(_ g: UInt64) {
    guard callId != nil else { return }
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    #endif
    set(.suspended)
    OLCallDiskLog.shared.mark("audio-engine", "suspended gen=\(g)")
  }

  private func enableAudio(generation g: UInt64) {
    if case .running(let cur) = phase, cur == g { return }
    #if canImport(WebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.isAudioEnabled = true
    if audioTrack == nil {
      let src = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
      audioTrack = factory.audioTrack(with: src, trackId: "ol-audio0")
    }
    audioTrack?.isEnabled = !muted
    set(.running(generation: g))
    #else
    set(.failed("WebRTC framework not linked"))
    #endif
    OLCallDiskLog.shared.mark("audio-engine", "enable gen=\(g) phase=\(phase)")
  }

  #if canImport(WebRTC)
  /// The local audio track to add to the call's RTCPeerConnection (transport per OL rtcSession contract).
  public var localAudioTrack: RTCAudioTrack? { audioTrack }
  #endif

  public func setMute(_ m: Bool) {
    muted = m
    #if canImport(WebRTC)
    audioTrack?.isEnabled = !m
    #endif
  }

  private func stopAudio() {
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    audioTrack?.isEnabled = false
    audioTrack = nil
    #endif
  }

  /// Every call end: full teardown so a redial starts from zero.
  public func end() {
    precondition(Thread.isMainThread)
    stopAudio(); callId = nil; wantMedia = false
    set(.idle)
  }

  public var isRunning: Bool { if case .running = phase { return true }; return false }

  private func set(_ p: Phase) { phase = p; onPhase?(p) }
}
