// Expo views for the PJSIP engine's video (b104). Signaling and media setup are native (CallSignalClient +
// NativeCallMedia, driven by OLCallManager / CallKit); JS only places these two views on the app's call screen.
import ExpoModulesCore

public final class OpenLoungeCallEngineModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OpenLoungeCallEngine")
    View(OLRemoteVideoView.self) {}
    View(OLLocalVideoView.self) {}
  }
}
