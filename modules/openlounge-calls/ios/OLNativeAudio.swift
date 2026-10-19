import AVFoundation
#if canImport(LiveKitWebRTC)
import LiveKitWebRTC
private typealias RTCAudioSession = LKRTCAudioSession
private typealias RTCAudioSessionConfiguration = LKRTCAudioSessionConfiguration
#endif

/// Native call media (src/nativeMedia.ts): CallKit owns the AVAudioSession; WebRTC's audio unit only runs while
/// CallKit says the session is live. Manual audio = WebRTC never activates/configures the session itself, so the
/// pre-warmed mic + transports built on dial/answer sit idle until didActivate flips isAudioEnabled (no renegotiation,
/// no fresh capture: the "Keiko can't hear the iPhone caller" race is gone by construction).
enum OLNativeAudio {
  static func setUp(video: Bool = false) {
    #if canImport(LiveKitWebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.useManualAudio = true
    rtc.isAudioEnabled = false
    // configure once: WebRTC's own default config must match what configureAudio() sets, so it never re-applies
    // a category/mode mid-call (each one is a route change + voice-processing reset).
    let cfg = RTCAudioSessionConfiguration.webRTC()
    cfg.category = AVAudioSession.Category.playAndRecord.rawValue
    // Match the active CallKit mode: only the explicit app-owned video call uses videoChat.
    cfg.mode = (video ? AVAudioSession.Mode.videoChat : AVAudioSession.Mode.voiceChat).rawValue
    cfg.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    RTCAudioSessionConfiguration.setWebRTC(cfg)
    #endif
  }

  static func didActivate(_ session: AVAudioSession, video: Bool = false) {
    #if canImport(LiveKitWebRTC)
    // Keep WebRTC's manual audio unit in the same mode CallKit has just activated.
    setUp(video: video)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(session)
    rtc.isAudioEnabled = true
    #endif
  }

  /// idle after a call: WebRTC's audio unit fully stopped so nothing keeps the session in voice-processing/call shape
  /// (that left-over state made the next ringtone thin and quiet on iPhone b39)
  static func stopIdle() {
    #if canImport(LiveKitWebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    if rtc.isAudioEnabled { rtc.isAudioEnabled = false }
    #endif
  }

  static func didDeactivate(_ session: AVAudioSession) {
    #if canImport(LiveKitWebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.isAudioEnabled = false
    rtc.audioSessionDidDeactivate(session)
    #endif
  }
}
