// JS API of the OpenLoungeOlcall Expo module, for the EXISTING OL call screen.
// The screen keeps its own look (peer avatar in the squircle, name, timer,
// controls); it only swaps its media calls to these and subscribes to state.
//
//   import * as olcall from '../openlounge-olcall/js/olcall';
//   const sub = olcall.addCallStateListener(setCallState);
//   await olcall.start({ url, token, video, peer });   // token = olcall token from call:accept
//   <olcall.OlcallVideoView source="remote" style={StyleSheet.absoluteFill} />
//   <olcall.OlcallVideoView source="local" style={styles.selfSquircle} />   // inside the existing squircle
//   olcall.setMuted(true); olcall.setCameraEnabled(false); olcall.switchCamera(); olcall.setSpeaker(true); olcall.hangup();
import { requireNativeModule, requireNativeViewManager, type EventSubscription } from 'expo-modules-core';
import type { ViewProps } from 'react-native';

export type CallPhase = 'connecting' | 'inCall' | 'reconnecting' | 'ended';

export interface CallPeer {
  userId: string;
  displayName: string;
  avatarUrl?: string | null;
}

export interface CallState {
  phase: CallPhase;
  isVideoCall: boolean;
  elapsedSec: number;
  muted: boolean;
  cameraOn: boolean;
  frontCamera: boolean;
  speakerOn: boolean;
  remoteMuted: boolean;
  remoteVideoOn: boolean;
  peer: CallPeer;
  endReason?: string;
  audioError?: string;
}

interface NativeOlcall {
  start(url: string, token: string, video: boolean, peerId: string, peerName: string, avatarUrl: string | null): Promise<void>;
  setMuted(muted: boolean): void;
  setCameraEnabled(on: boolean): void;
  switchCamera(): void;
  setSpeaker(on: boolean): void;
  hangup(): void;
  addListener(event: 'onCallState', cb: (s: CallState) => void): EventSubscription;
}

const native = requireNativeModule<NativeOlcall>('OpenLoungeOlcall');

export function start(opts: { url: string; token: string; video: boolean; peer: CallPeer }): Promise<void> {
  if (!/^wss?:\/\//.test(opts.url)) throw new Error('olcall: url must be ws(s)://.../v1/call');
  return native.start(opts.url, opts.token, opts.video, opts.peer.userId, opts.peer.displayName, opts.peer.avatarUrl ?? null);
}

export const setMuted = (muted: boolean) => native.setMuted(muted);
export const setCameraEnabled = (on: boolean) => native.setCameraEnabled(on);
export const switchCamera = () => native.switchCamera();
export const setSpeaker = (on: boolean) => native.setSpeaker(on);
export const hangup = () => native.hangup();

export function addCallStateListener(cb: (s: CallState) => void): EventSubscription {
  return native.addListener('onCallState', cb);
}

export type OlcallVideoViewProps = ViewProps & { source: 'remote' | 'local' };
export const OlcallVideoView = requireNativeViewManager<OlcallVideoViewProps>('OpenLoungeOlcall');

/** Timer text the existing screen already shows (mm:ss / h:mm:ss). */
export function formatElapsed(sec: number): string {
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  const mm = String(m).padStart(h ? 2 : 1, '0'), ss = String(s).padStart(2, '0');
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}
