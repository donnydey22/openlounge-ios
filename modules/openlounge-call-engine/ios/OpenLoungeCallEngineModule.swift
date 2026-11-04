// Expo bridge for the PJSIP engine (M4 option B). The RN side runs the SFU PlainTransport RPCs through the page's
// authenticated socket and hands only the resulting tuple + SDES keys here. Audio opens on CallKit didActivate.
import ExpoModulesCore
import AVFoundation

public final class OpenLoungeCallEngineModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OpenLoungeCallEngine")
    Function("newSrtpKey") { () -> String in
      var b = [UInt8](repeating: 0, count: 30)
      _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
      return Data(b).base64EncodedString()
    }
    Function("sfuAudioStart") { (ip: String, port: Int, txKey: String, rxKey: String, ssrc: Double, txPt: Int, rxPt: Int) -> Int in
      PJSIPEngine.shared.start()
      return Int(ol_sfu_audio_start(ip, Int32(port), txKey, rxKey, UInt32(ssrc), Int32(txPt), Int32(rxPt), 0))
    }
    Function("sfuStats") { () -> [Int] in
      var rx: UInt32 = 0, lost: UInt32 = 0, tx: UInt32 = 0
      _ = ol_sfu_stats(&rx, &lost, &tx)
      return [Int(rx), Int(lost), Int(tx)]
    }
    Function("setMute") { (muted: Bool) -> Int in Int(ol_sfu_set_mute(muted ? 1 : 0)) }
    Function("sfuStop") { () in ol_sfu_stop(); PJSIPEngine.shared.teardown() }
    // Video leg: own PlainTransport ("video" purpose) + SRTP key, 3 simulcast SSRCs, H.264 PT 102
    Function("sfuVideoStart") { (ip: String, port: Int, txKey: String, rxKey: String, ssrcs: [Double], pt: Int) -> Int in
      OLCallVideo.shared.start(ip: ip, port: port, txKey: txKey, rxKey: rxKey, ssrcs: ssrcs.map { UInt32($0) }, pt: pt)
    }
    AsyncFunction("camera") { (on: Bool, facing: String) in try OLCallVideo.shared.camera(on: on, facing: facing) }
    Function("sfuVideoStats") { () -> [Int] in OLCallVideo.shared.stats() }
    Function("sfuVideoStop") { () in OLCallVideo.shared.stop() }
    Events("onRemoteVideo")
    OnStartObserving { OLCallVideo.shared.onRemoteFirstFrame = { [weak self] in self?.sendEvent("onRemoteVideo", ["on": true]) } }
    OnStopObserving { OLCallVideo.shared.onRemoteFirstFrame = nil }
    View(OLRemoteVideoView.self) {}
    View(OLLocalVideoView.self) {}
  }
}
