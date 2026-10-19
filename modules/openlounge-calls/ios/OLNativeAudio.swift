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
  static func setUp() {
    #if canImport(LiveKitWebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.useManualAudio = true
    rtc.isAudioEnabled = false
    // configure once: WebRTC's own default config must match what configureAudio() sets, so it never re-applies
    // a category/mode mid-call (each one is a route change + voice-processing reset).
    let cfg = RTCAudioSessionConfiguration.webRTC()
    cfg.category = AVAudioSession.Category.playAndRecord.rawValue
    cfg.mode = AVAudioSession.Mode.voiceChat.rawValue
    cfg.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    RTCAudioSessionConfiguration.setWebRTC(cfg)
    #endif
  }

  static func didActivate(_ session: AVAudioSession) {
    #if canImport(LiveKitWebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(session)
    rtc.isAudioEnabled = true
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
