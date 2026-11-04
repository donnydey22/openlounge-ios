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
      PJSIPEngine.shared.audioStart(ip: ip, port: port, txKey: txKey, rxKey: rxKey, ssrc: UInt32(ssrc), txPt: Int32(txPt), rxPt: Int32(rxPt))
    }
    Function("setMute") { (muted: Bool) -> Int in PJSIPEngine.shared.setMute(muted) }
    Function("sfuStop") { () in PJSIPEngine.shared.audioStop() }
    // Video leg: own PlainTransport ("video" purpose) + SRTP key, 3 simulcast SSRCs, H.264 PT 102
    Function("sfuVideoStart") { (ip: String, port: Int, txKey: String, rxKey: String, ssrcs: [Double], pt: Int) -> Int in
      PJSIPEngine.shared.q.sync { OLCallVideo.shared.start(ip: ip, port: port, txKey: txKey, rxKey: rxKey, ssrcs: ssrcs.map { UInt32($0) }, pt: pt) }
    }
    AsyncFunction("camera") { (on: Bool, facing: String) in try OLCallVideo.shared.camera(on: on, facing: facing) }
    Function("sfuVideoStop") { () in PJSIPEngine.shared.q.sync { OLCallVideo.shared.stop() } }
    Events("onRemoteVideo", "onAudioStats")
    OnStartObserving {
      OLCallVideo.shared.onRemoteFirstFrame = { [weak self] in self?.sendEvent("onRemoteVideo", ["on": true]) }
      PJSIPEngine.shared.onAudioStats = { [weak self] s in self?.sendEvent("onAudioStats", s) }
    }
    OnStopObserving { OLCallVideo.shared.onRemoteFirstFrame = nil; PJSIPEngine.shared.onAudioStats = nil }
    View(OLRemoteVideoView.self) {}
    View(OLLocalVideoView.self) {}
  }
}
