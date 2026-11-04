// PJSIP M4 option B (iOS): page op:"connect"{callId} -> SFU PlainTransport RPCs over the page's authenticated socket
// (window.__olNativeMsReq -> msReply) -> native engine SRTP audio leg. Mirrors Android NativeCallMedia.kt (8f6f4d0).
import { requireOptionalNativeModule } from 'expo-modules-core';

type Engine = { newSrtpKey(): string; sfuAudioStart(ip: string, port: number, tx: string, rx: string, ssrc: number, txPt: number, rxPt: number): number; sfuStats(): number[]; sfuStop(): void };
const engine = requireOptionalNativeModule<Engine>('OpenLoungeCallEngine');
export type MsRpc = (event: string, data: Record<string, unknown>) => Promise<any>;

export function createPjsipController(rpc: MsRpc) {
  let leg: { ip: string; port: number; tx: string; rx: string; ssrc: number; rxPt: number } | null = null;
  const start = () => (leg && engine ? engine.sfuAudioStart(leg.ip, leg.port, leg.tx, leg.rx, leg.ssrc, 111, leg.rxPt) : -1);
  return {
    async handle(v: any): Promise<any> {
      const op = v?.op;
      if (op === 'prewarm') return { engine: engine ? 'pjsip' : 'missing' };
      if (op === 'close' || op === 'end') { this.closeAll(); return true; }
      if (op === 'stats') { const s = engine?.sfuStats() ?? []; return { rxPkt: s[0], rxLost: s[1], txPkt: s[2] }; }
      if (op === 'mute') return true; // TODO engine mute
      if (op !== 'connect') throw new Error(`unknown op: ${op}`);
      if (!engine) throw new Error('pjsip engine missing');
      const callId = String(v.callId ?? '');
      if (!callId) throw new Error('callId required');
      const d = () => ({ callId });
      const tx = engine.newSrtpKey(); const ssrc = 100000 + Math.floor(Math.random() * 1_000_000);
      await rpc('ms:join', d());
      const c = await rpc('ms:plain:create', d());
      await rpc('ms:plain:connect', { ...d(), srtpParameters: { cryptoSuite: 'AES_CM_128_HMAC_SHA1_80', keyBase64: tx } });
      await rpc('ms:plain:produce', { ...d(), kind: 'audio', ssrc, payloadType: 111 });
      const cons = await rpc('ms:plain:consume', d()).catch(() => null);
      leg = { ip: c.ip, port: c.port, tx, rx: c.srtpParameters?.keyBase64, ssrc, rxPt: cons?.consumers?.[0]?.payloadType ?? 100 };
      // Sound device opens on CallKit didActivate (PJSIPEngine.audioSessionDidActivate); the SRTP leg starts now.
      const r = start();
      if (r !== 0) throw new Error(`pjsip audio leg start failed: ${r}`);
      return { engine: 'pjsip' };
    },
    closeAll() { leg = null; engine?.sfuStop(); },
    onNetworkChange() { if (leg && engine) { engine.sfuStop(); start(); } },
  };
}
