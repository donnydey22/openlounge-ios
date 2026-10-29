import AVFoundation
// Stream's WebRTC build (StreamWebRTC 125.6422, m125: the same WebRTC as ChatSwap's stream-webrtc-android 1.3.10),
// shared with @stream-io/react-native-webrtc. Classes keep the stock RTC prefix. Fail the build loudly rather than
// ship a call lane whose CallKit audio silently never starts.
#if canImport(WebRTC)
import WebRTC
#else
#error("OpenLoungeCalls requires StreamWebRTC (module WebRTC, via @stream-io/react-native-webrtc)")
#endif

/// Native call media (src/nativeMedia.ts): CallKit owns the AVAudioSession; WebRTC's audio unit only runs while
/// CallKit says the session is live. Manual audio = WebRTC never activates/configures the session itself, so the
/// pre-warmed mic + transports built on dial/answer sit idle until didActivate flips isAudioEnabled (no renegotiation,
/// no fresh capture: the "Keiko can't hear the iPhone caller" race is gone by construction).
enum OLNativeAudio {
  static func setUp(video: Bool = false, session: AVAudioSession = AVAudioSession.sharedInstance()) {
    #if canImport(WebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.useManualAudio = true
    rtc.isAudioEnabled = false
    // CallKit has already selected the route. Copy its live category, mode, and options into WebRTC instead of
    // reintroducing WebRTC's receiver-oriented defaults when its manual audio unit starts. This retains
    // defaultToSpeaker for the normal call speaker route, while leaving Bluetooth/headset and an explicit receiver
    // selection under OLCallManager's control.
    let cfg = RTCAudioSessionConfiguration.webRTC()
    let callCategory: AVAudioSession.Category = session.category == .playAndRecord ? session.category : .playAndRecord
    let callMode: AVAudioSession.Mode = (session.mode == .voiceChat || session.mode == .videoChat)
      ? session.mode
      : (video ? .videoChat : .voiceChat)
    cfg.category = callCategory.rawValue
    cfg.mode = callMode.rawValue
    cfg.categoryOptions = session.categoryOptions
    RTCAudioSessionConfiguration.setWebRTC(cfg)
    #endif
  }

  static func didActivate(_ session: AVAudioSession, video: Bool = false) {
    #if canImport(WebRTC)
    // The session was configured by CallKit immediately before this callback; make the manual WebRTC audio unit match.
    setUp(video: video, session: session)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(session)
    rtc.isAudioEnabled = true
    #endif
  }

  /// idle after a call: WebRTC's audio unit fully stopped so nothing keeps the session in voice-processing/call shape
  /// (that left-over state made the next ringtone thin and quiet on iPhone b39)
  static func stopIdle() {
    #if canImport(WebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    if rtc.isAudioEnabled { rtc.isAudioEnabled = false }
    #endif
  }

  static func didDeactivate(_ session: AVAudioSession) {
    #if canImport(WebRTC)
    let rtc = RTCAudioSession.sharedInstance()
    rtc.isAudioEnabled = false
    rtc.audioSessionDidDeactivate(session)
    #endif
  }
}
