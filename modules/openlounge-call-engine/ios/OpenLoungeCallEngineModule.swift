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
    Function("sfuStop") { () in ol_sfu_stop(); PJSIPEngine.shared.teardown() }
  }
}
