// OpenLoungeCallEngine: call CONTROL only (CallSignalClient on the app's openlounge.app/ws socket: ring, start, accept,
// decline, hangup, call:get, the CallMedia/olcall token hand-off) + OLCallDiskLog. Media is the one olcall engine
// (modules/openlounge-olcall: tgcalls <-> olcall Go/Pion, wss://<host>/v1/call); video views live in OLNativeCallHost.
// The old WebRTC.xcframework media path (OLRtcCall / OLRtcVideo / OLCallAudioEngine / sealed rc:*) is removed.
import ExpoModulesCore

public final class OpenLoungeCallEngineModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OpenLoungeCallEngine")
  }
}
