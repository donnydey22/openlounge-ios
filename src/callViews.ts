// Call video is native: tgcalls (olcall engine, modules/openlounge-olcall) video views are placed by the native call
// screen (OLNativeCallHost). The old WebRTC Expo views (OLRtcVideo) are removed with the WebRTC.xcframework path, so
// the RN layer renders no call video. callEngineAvailable = the olcall engine module is linked.
import { requireOptionalNativeModule } from 'expo-modules-core';

const olcall = requireOptionalNativeModule('OpenLoungeOlcall');
export const callEngineAvailable = () => !!olcall;
export const RemoteVideoView: any = null;
export const LocalVideoView: any = null;
