// PJSIP M4 option B (iOS): page op:"connect"{callId} -> SFU PlainTransport RPCs over the page's authenticated socket
// (window.__olNativeMsReq -> msReply) -> native engine SRTP legs. Audio: one "audio" PlainTransport (Opus PT 111).
// Video: own "video" PlainTransport + key, 3 simulcast SSRCs, H.264 PT 102 (VideoToolbox; browser peers decode H.264).
import { requireOptionalNativeModule, requireNativeViewManager as requireNativeView } from 'expo-modules-core';

type Engine = {
  newSrtpKey(): string;
  sfuAudioStart(ip: string, port: number, tx: string, rx: string, ssrc: number, txPt: number, rxPt: number): number;
  sfuStats(): number[]; sfuStop(): void; setMute(muted: boolean): number;
  sfuVideoStart(ip: string, port: number, tx: string, rx: string, ssrcs: number[], pt: number): number;
  camera(on: boolean, facing: string): Promise<void>; sfuVideoStats(): number[]; sfuVideoStop(): void;
  addListener?(ev: string, cb: (e: any) => void): { remove(): void };
};
const engine = requireOptionalNativeModule<Engine>('OpenLoungeCallEngine');
export const pjsipAvailable = () => !!engine;
export const RemoteVideoView: any = engine ? requireNativeView('OpenLoungeCallEngine', 'OLRemoteVideoView') : null;
export const LocalVideoView: any = engine ? requireNativeView('OpenLoungeCallEngine', 'OLLocalVideoView') : null;
export type MsRpc = (event: string, data: Record<string, unknown>) => Promise<any>;
export type PjsipHooks = { onVideo?(s: { callId: string; local: boolean; remote: boolean; facing: string } | null): void };

const SRTP = 'AES_CM_128_HMAC_SHA1_80';
const rnd = (base: number) => base + Math.floor(Math.random() * 1_000_000);

export function createPjsipController(rpc: MsRpc, hooks: PjsipHooks = {}) {
  let leg: { callId: string; ip: string; port: number; tx: string; rx: string; ssrc: number; rxPt: number; haveRx: boolean } | null = null;
  let audioPoll: ReturnType<typeof setInterval> | null = null;
  let video: { callId: string; started: boolean; local: boolean; remote: boolean; facing: string } | null = null;
  let sub: { remove(): void } | null = null;
  let poll: ReturnType<typeof setInterval> | null = null;
  const start = () => (leg && engine ? engine.sfuAudioStart(leg.ip, leg.port, leg.tx, leg.rx, leg.ssrc, 111, leg.rxPt) : -1);
  const emit = () => hooks.onVideo?.(video ? { callId: video.callId, local: video.local, remote: video.remote, facing: video.facing } : null);

  async function startVideo(callId: string) {
    if (!engine || video?.started) return;
    const d = { callId, purpose: 'video' };
    const tx = engine.newSrtpKey();
    const ssrcs = [rnd(5_000_000), rnd(6_000_000), rnd(7_000_000)];
    const c = await rpc('ms:plain:create', d);
    await rpc('ms:plain:connect', { ...d, srtpParameters: { cryptoSuite: SRTP, keyBase64: tx } });
    const r = engine.sfuVideoStart(c.ip, c.port, tx, c.srtpParameters?.keyBase64, ssrcs, 102);
    if (r !== 0) throw new Error(`pjsip video leg start failed: ${r}`);
    await rpc('ms:plain:produce', { callId, kind: 'video', ssrcs, payloadType: 102, codec: 'h264', platform: 'ios' });
    video = { ...(video ?? { callId, local: false, remote: false, facing: 'user' }), started: true };
    sub = engine.addListener?.('onRemoteVideo', () => { if (video) { video.remote = true; emit(); } }) ?? null;
    // the peer's camera may come later: keep consuming video until it arrives
    const consume = async () => { if (!video || video.remote) return; const x = await rpc('ms:plain:consume', d).catch(() => null);
      if (x?.consumers?.some((k: any) => k.kind === 'video')) { if (poll) clearInterval(poll); poll = null; } };
    poll = setInterval(consume, 1500); await consume();
  }

  return {
    async handle(v: any): Promise<any> {
      const op = v?.op;
      if (op === 'prewarm') return { engine: engine ? 'pjsip' : 'missing' };
      if (op === 'close' || op === 'end') { this.closeAll(); return true; }
      if (op === 'stats') { const s = engine?.sfuStats() ?? []; const vs = video?.started ? engine?.sfuVideoStats() ?? [] : [];
        return [[{ id: 'pjsip-audio', type: 'pjsip', rxPkt: s[0], rxLost: s[1], txPkt: s[2] }, ...(vs.length ? [{ id: 'pjsip-video', type: 'pjsip-video', rxPkt: vs[0], rxAu: vs[1], txPkt: vs[4], txAu: vs[5], frames: vs[7] }] : [])]]; }
      if (op === 'mute') return (engine?.setMute(v.muted === true) ?? -1) === 0;
      if (op === 'camera') {
        if (!engine || !leg) throw new Error('no call');
        const on = v.on === true, facing = v.facing === 'environment' ? 'environment' : 'user';
        if (on && !video?.started) await startVideo(String(v.callId ?? video?.callId ?? ''));
        await engine.camera(on, facing);
        if (video) { video.local = on; video.facing = facing; emit(); }
        return true;
      }
      if (op !== 'connect') throw new Error(`unknown op: ${op}`);
      if (!engine) throw new Error('pjsip engine missing');
      const callId = String(v.callId ?? '');
      if (!callId) throw new Error('callId required');
      const d = () => ({ callId });
      // idempotent: a second connect for the same live call keeps the running leg (a restart used to drop sound)
      if (leg && leg.callId === callId) return { engine: 'pjsip', video: !!video?.started };
      const tx = engine.newSrtpKey(); const ssrc = rnd(100000);
      await rpc('ms:join', d());
      const c = await rpc('ms:plain:create', d());
      await rpc('ms:plain:connect', { ...d(), srtpParameters: { cryptoSuite: SRTP, keyBase64: tx } });
      await rpc('ms:plain:produce', { ...d(), kind: 'audio', ssrc, payloadType: 111 });
      const cons = await rpc('ms:plain:consume', d()).catch(() => null);
      const a = cons?.consumers?.find((k: any) => k.kind === 'audio');
      leg = { callId, ip: c.ip, port: c.port, tx, rx: c.srtpParameters?.keyBase64, ssrc, rxPt: a?.payloadType ?? 100, haveRx: !!a };
      // Sound device opens on CallKit didActivate (PJSIPEngine); a leg started after activation reopens it itself.
      const r = start();
      if (r !== 0) throw new Error(`pjsip audio leg start failed: ${r}`);
      // Symmetric with the web/Android leg: the peer may produce AFTER us (iPhone answers faster than Android connects),
      // so keep consuming until its audio exists, then restart the leg on the real payload type.
      if (!a) {
        const l = leg;
        audioPoll = setInterval(async () => {
          if (leg !== l) { if (audioPoll) clearInterval(audioPoll); audioPoll = null; return; }
          const x = await rpc('ms:plain:consume', d()).catch(() => null);
          const au = x?.consumers?.find((k: any) => k.kind === 'audio');
          if (!au || leg !== l) return;
          if (audioPoll) clearInterval(audioPoll); audioPoll = null;
          l.haveRx = true;
          if (au.payloadType !== l.rxPt) { l.rxPt = au.payloadType; engine.sfuStop(); start(); }
        }, 700);
      }
      if (v.video === true) {
        video = { callId, started: false, local: false, remote: false, facing: 'user' };
        await startVideo(callId);
        // camera opens only after didActivate; the native gate throws until then, so retry briefly
        for (let i = 0; i < 20; i++) { try { await engine.camera(true, 'user'); video.local = true; break; } catch { await new Promise((ok) => setTimeout(ok, 250)); } }
        emit();
      }
      return { engine: 'pjsip', video: !!video?.started };
    },
    closeAll() {
      if (poll) clearInterval(poll); poll = null; sub?.remove(); sub = null;
      if (video) { if (video.started) engine?.sfuVideoStop(); video = null; emit(); }
      if (audioPoll) clearInterval(audioPoll); audioPoll = null;
      leg = null; engine?.sfuStop();
    },
    onNetworkChange() { if (leg && engine) { engine.sfuStop(); start(); } },
  };
}
