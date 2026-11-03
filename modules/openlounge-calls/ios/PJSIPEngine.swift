// Open Lounge PJSIP media engine (pjproject 2.17). One path for every call.
// Rules: never calls AVAudioSession.setActive; sound device opened only after
// CallKit didActivate AND session confirmed active; full teardown on every end.
import AVFoundation
import pjproject

final class PJSIPEngine {
  static let shared = PJSIPEngine()
  private(set) var audioRunning = false

  func start() {
    var cfg = pjsua_config(); pjsua_config_default(&cfg)
    var media = pjsua_media_config(); pjsua_media_config_default(&media)
    // Adaptive jitter buffer (pjmedia_jbuf), progressive discard, PLC on.
    media.jb_init = -1; media.jb_min_pre = 1; media.jb_max_pre = 16; media.jb_max = 50
    media.jb_discard_algo = PJMEDIA_JB_DISCARD_PROGRESSIVE
    media.no_vad = 1; media.clock_rate = 48000; media.snd_clock_rate = 48000
    pjsua_create()
    pjsua_init(&cfg, nil, &media)
    pjsua_start()
    pjsua_set_no_snd_dev()                      // no audio until didActivate
  }

  /// SRTP SDES mandatory: keys carried only in a=crypto of offer/answer.
  func applySrtp(_ acc: inout pjsua_acc_config) {
    acc.use_srtp = PJMEDIA_SRTP_MANDATORY
    acc.srtp_secure_signaling = 0               // TLS WS carries SDP, not SIP-TLS
    acc.srtp_opt.keying_count = 1
    acc.srtp_opt.keying.0 = PJMEDIA_SRTP_KEYING_SDES
  }

  /// Called only from provider(_:didActivate:).
  func audioSessionDidActivate(_ session: AVAudioSession) {
    guard !audioRunning else { return }
    guard session.currentRoute.inputs.isEmpty == false else { return } // session confirmed active
    if pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV.rawValue, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV.rawValue) == PJ_SUCCESS.rawValue {
      audioRunning = true
    }
  }

  func audioSessionDidDeactivate() { pjsua_set_no_snd_dev(); audioRunning = false }

  /// Full teardown on every call end so a redial starts from zero.
  func teardown() {
    pjsua_call_hangup_all()
    pjsua_set_no_snd_dev(); audioRunning = false
  }
}
