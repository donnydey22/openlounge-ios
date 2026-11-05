// b104: the PJSIP engine's two video views (modules/openlounge-call-engine). Signaling + media are native
// (CallSignalClient / NativeCallMedia); this file only exposes the views for the app's own call screen.
import { requireOptionalNativeModule, requireNativeViewManager } from 'expo-modules-core';

const engine = requireOptionalNativeModule('OpenLoungeCallEngine');
export const pjsipAvailable = () => !!engine;
export const RemoteVideoView: any = engine ? requireNativeViewManager('OpenLoungeCallEngine', 'OLRemoteVideoView') : null;
export const LocalVideoView: any = engine ? requireNativeViewManager('OpenLoungeCallEngine', 'OLLocalVideoView') : null;
