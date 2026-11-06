// Expo views for call video (OLRtcVideo: WebRTC tracks on the one OLRtcCall PeerConnection). Signaling/media are native
// (CallSignalClient + OLRtcCall, driven by OLCallManager / CallKit); JS only places these two views on the call screen.
import ExpoModulesCore

public final class OpenLoungeCallEngineModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OpenLoungeCallEngine")
    View(OLRemoteVideoView.self) {}
    View(OLLocalVideoView.self) {}
  }
}
