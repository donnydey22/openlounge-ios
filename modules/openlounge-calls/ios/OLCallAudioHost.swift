// Boundary marker: Swift owns call audio from first launch (Linphone-spec).
// Full SwiftUI call screens land in a later cut; this type is the audio-path host so the RN/WebView
// root is never an AVAudioSession client for 1:1 calls. OLCallManager + OLAudioSessionOwner are the owners.
import Foundation

@objc(OLCallAudioHost)
public final class OLCallAudioHost: NSObject {
  @objc public static let shared = OLCallAudioHost()
  /// Ensure the session owner exists as soon as the calls module loads.
  @objc public func armAtLaunch() {
    _ = OLAudioSessionOwner.shared
  }
}
