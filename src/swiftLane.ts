// b75 single path: Android → iPhone incoming AUDIO calls answered on iOS use the native Swift lane
// (modules/openlounge-calls/ios/OLNativeAudioLane.swift: RTCPeerConnection on StreamWebRTC 125.6422.070, no
// libmediasoupclient). Every other combination (iOS↔iOS, iOS→Android, outgoing, video, rooms) is untouched.
import { Platform } from 'react-native';
import { requireOptionalNativeModule } from 'expo';

type Sub = { remove(): void };
type LaneNative = {
  laneConnect(callId: string, nativeConn: string, iceJson: string): Promise<boolean>;
  msResponse(id: string, ok: boolean, json: string, error: string): void;
  laneControl(op: string, flag: boolean): boolean;
  addListener(event: 'onMsRequest', fn: (e: { id: string; event: string; json: string }) => void): Sub;
  addListener(event: 'onLaneEvent', fn: (e: Record<string, unknown>) => void): Sub;
};

/** callId → caller platform, recorded ONLY from incoming call-start payloads (so presence ⇒ incoming call). */
const incomingPeer = new Map<string, string>();

/** Reads the caller platform from a call-start payload: `callerPlatform`, `peerPlatform`, `platform`, or `caller.platform`. */
export function callerPlatformOf(v: Record<string, unknown> | null | undefined): string | null {
  if (!v) return null;
  const caller = (v.caller ?? (v.call as Record<string, unknown> | undefined)?.caller) as Record<string, unknown> | undefined;
  const p = v.callerPlatform ?? v.peerPlatform ?? v.platform ?? caller?.platform ?? (v.call as Record<string, unknown> | undefined)?.callerPlatform;
  return typeof p === 'string' ? p.toLowerCase().slice(0, 12) : null;
}

/** b80: the live Android → iPhone audio call (native-only media): the WebView may not capture mic/audio for it. */
let laneCall: string | null = null;
const laneWatchers = new Set<(id: string | null) => void>();
function setLaneCall(id: string | null) { if (laneCall !== id) { laneCall = id; laneWatchers.forEach((f) => f(id)); } }
export function androidLaneCall() { return laneCall; }
export function watchAndroidLaneCall(f: (id: string | null) => void) { laneWatchers.add(f); return () => { laneWatchers.delete(f); }; }

export function noteIncoming(v: Record<string, unknown>) {
  if (v?.type === 'call:ended' && typeof v.callId === 'string') { if (laneCall === v.callId) setLaneCall(null); return; }
  if (v?.type !== 'call:incoming' || typeof v.callId !== 'string') return;
  const p = callerPlatformOf(v);
  if (p) incomingPeer.set(v.callId, p);
  if (Platform.OS === 'ios' && v.video !== true && p === 'android') setLaneCall(v.callId);
  if (incomingPeer.size > 32) incomingPeer.delete(incomingPeer.keys().next().value as string);
}
export function forgetCall(callId: unknown) { if (typeof callId === 'string') { incomingPeer.delete(callId); if (laneCall === callId) setLaneCall(null); } }

/** Pure routing decision (unit-tested): Swift lane only for iOS + incoming + Android caller + audio-only. */
export function routeSwiftLane(x: { os: string; video: boolean; incoming: boolean; peerPlatform: string | null }): boolean {
  return x.os === 'ios' && !x.video && x.incoming && x.peerPlatform === 'android';
}

export function shouldUseSwiftLane(cmd: Record<string, unknown>): boolean {
  const callId = typeof cmd.callId === 'string' ? cmd.callId : '';
  const fromMap = incomingPeer.get(callId) ?? null;
  const fromCmd = typeof cmd.peerPlatform === 'string' && cmd.incoming === true ? cmd.peerPlatform.toLowerCase() : null;
  const peer = fromMap ?? fromCmd;
  return !!laneNative() && routeSwiftLane({ os: Platform.OS, video: cmd.video === true, incoming: peer != null, peerPlatform: peer });
}

let mod: LaneNative | null | undefined;
function laneNative(): LaneNative | null {
  if (mod !== undefined) return mod;
  try {
    const m = requireOptionalNativeModule<LaneNative>('OpenLoungeCalls');
    mod = m && typeof (m as Partial<LaneNative>).laneConnect === 'function' ? m : null;
  } catch { mod = null; }
  return mod;
}

type Req = <T>(event: string, data: Record<string, unknown>) => Promise<T>;
const MS_EVENT = /^ms:[a-z:]{2,40}$/;

/** JS side of the Swift lane: relays ms:* over the existing page socket bridge; never touches media. */
export class SwiftLane {
  callId: string | null = null;
  connected = false;
  private subs: Sub[] = [];
  constructor(private req: Req, private emit: (d: Record<string, unknown>) => void) {
    const n = laneNative();
    if (!n) return;
    this.subs.push(n.addListener('onMsRequest', (e) => {
      if (!MS_EVENT.test(e.event)) { n.msResponse(e.id, false, '', 'refused'); return; }
      let data: Record<string, unknown> = {};
      try { data = JSON.parse(e.json); } catch {}
      this.req<unknown>(e.event, data).then(
        (r) => n.msResponse(e.id, true, JSON.stringify(r ?? {}), ''),
        (err: unknown) => n.msResponse(e.id, false, '', String((err as Error)?.message ?? err)),
      );
    }));
    this.subs.push(n.addListener('onLaneEvent', (d) => {
      if (d.callId !== this.callId) return;
      if (d.state === 'connected') this.connected = true;
      if (d.state === 'diag') { this.emit({ state: 'diag', lane: 'swift', stage: d.stage, ms: d.ms }); return; }
      this.emit({ ...d, lane: 'swift' });
    }));
  }
  async connect(callId: string, nativeConn: string, iceServers: unknown[]) {
    const n = laneNative();
    if (!n) throw new Error('swift lane unavailable');
    this.callId = callId;
    this.connected = false;
    await n.laneConnect(callId, nativeConn, JSON.stringify(iceServers ?? []));
    this.connected = true;
    return { attached: false, lane: 'swift' };
  }
  control(op: 'mute' | 'close' | 'sync', flag = false) {
    if (op === 'close') { forgetCall(this.callId); this.callId = null; this.connected = false; }
    return laneNative()?.laneControl(op, flag) ?? false;
  }
}
