// Call video views (modules/openlounge-call-engine OLRtcVideo: WebRTC tracks on the one OLRtcCall PeerConnection).
// Signaling + media are native (CallSignalClient / OLRtcCall, RingRTC session model); this file only exposes the views.
import { requireOptionalNativeModule, requireNativeViewManager } from 'expo-modules-core';

const engine = requireOptionalNativeModule('OpenLoungeCallEngine');
export const callEngineAvailable = () => !!engine;
export const RemoteVideoView: any = engine ? requireNativeViewManager('OpenLoungeCallEngine', 'OLRemoteVideoView') : null;
export const LocalVideoView: any = engine ? requireNativeViewManager('OpenLoungeCallEngine', 'OLLocalVideoView') : null;
