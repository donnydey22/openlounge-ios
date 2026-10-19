// Native call media (iOS): the app, not the WebView, owns the microphone, the mediasoup send/recv transports and
// the AVAudioSession (CallKit-driven, see OLCallManager.swift: RTCAudioSession.useManualAudio + isAudioEnabled on
// didActivate). The web page stays the call UI + signaling: it relays every ms:* request over its authenticated
// realtime socket (window.__olNativeMsReq) and forwards ms:consumer:available here.
//
// Page → app  (bridge method 'nativeMedia', request/reply):
//   {op:'prewarm'}                          dial tapped: grab the mic + load the WebRTC stack before the invite
//   {op:'connect', callId, iceServers, tcpOnly?}   join + send/recv transports + audio producer + consume
//   {op:'connectLiveKit', callId, url, token, iceServers}   emergency LiveKit path, still native
//   {op:'status'}  → {callId, kind, connected} | null    (a reloaded page re-attaches; connect on the same call = attach)
//   {op:'mute', muted} | {op:'close'} | {op:'restartIce'} | {op:'stats'} | {op:'ladder', audioBps}
//   {op:'consumerAvailable'}                ms:consumer:available arrived on the page socket
// App → page events (CustomEvent 'openlounge:native-media'): {state:'connected'|'disconnected'|'failed'|'remote-audio'}
import { mediaDevices, type MediaStream } from '@livekit/react-native-webrtc';
import { registerGlobals } from '@livekit/react-native';

type Req = <T>(event: string, data: Record<string, unknown>) => Promise<T>;
type Emit = (detail: Record<string, unknown>) => void;

let globalsDone = false;
function ensureGlobals() {
  if (globalsDone) return;
  registerGlobals();
  globalsDone = true;
}

/** mic captured on dial/answer, before CallKit activates the session (audio flows only once isAudioEnabled) */
let preStream: Promise<MediaStream | null> | null = null;

export function prewarmNativeMedia(): void {
  ensureGlobals();
  if (!preStream) {
    preStream = mediaDevices
      .getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } as never, video: false })
      .then((s) => s as MediaStream)
      .catch(() => null);
  }
  // load mediasoup-client now so connect() is pure network work
  void import('mediasoup-client').catch(() => {});
}

async function takeMic(): Promise<MediaStream | null> {
  const p = preStream;
  preStream = null;
  const s = p ? await p : null;
  if (s && s.getAudioTracks().some((t) => t.readyState === 'live')) return s;
  s?.getTracks().forEach((t) => t.stop());
  ensureGlobals();
  return (await mediaDevices.getUserMedia({ audio: true, video: false }).catch(() => null)) as MediaStream | null;
}

type Transport = {
  id: string;
  connectionState: string;
  on(ev: string, fn: (...a: any[]) => void): void;
  produce(o: Record<string, unknown>): Promise<Producer>;
  consume(o: Record<string, unknown>): Promise<Consumer>;
  restartIce(o: { iceParameters: unknown }): Promise<void>;
  getStats(): Promise<Map<string, Record<string, unknown>>>;
  close(): void;
};
type Producer = { id: string; pause(): void; resume(): void; close(): void; rtpSender?: { getParameters(): any; setParameters(p: any): Promise<void> } };
type Consumer = { id: string; kind: string; close(): void };

const CONNECT_TIMEOUT_MS = 12_000;

export class NativeMediaSession {
  private send: Transport | null = null;
  private recv: Transport | null = null;
  private device: { rtpCapabilities: unknown; load(o: unknown): Promise<void>; createSendTransport(o: unknown): Transport; createRecvTransport(o: unknown): Transport } | null = null;
  private producer: Producer | null = null;
  private stream: MediaStream | null = null;
  private consumers = new Map<string, Consumer>();
  private closed = false;
  private joined = false;
  private connected = false;
  private syncing: Promise<void> | null = null;
  private syncAgain = false;
  private iceRestarted = new Set<string>();

  /** stable server-side connection id for this media session: a page reload (new socket) re-attaches to it instead
   *  of the server tearing the SFU peer down with the old socket */
  readonly nativeConn = `n_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;

  constructor(readonly callId: string, private iceServers: unknown[], readonly tcpOnly: boolean, private req: Req, private emit: Emit) {}

  get alive() {
    return !this.closed;
  }
  get isConnected() {
    return this.connected && !this.closed;
  }

  private r<T>(event: string, data: Record<string, unknown> = {}) {
    return this.req<T>(event, { callId: this.callId, nativeConn: this.nativeConn, ...data });
  }

  async connect(): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | null = null;
    try {
      await Promise.race([
        this.connectInner(),
        new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new Error('native media connect timed out')), CONNECT_TIMEOUT_MS); }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  private check() {
    if (this.closed) throw new Error('native media closed');
  }

  private async connectInner() {
    ensureGlobals();
    const [{ Device }, stream] = await Promise.all([import('mediasoup-client'), takeMic()]);
    this.check();
    if (!stream) throw new Error('microphone unavailable');
    this.stream = stream;
    const joined = await this.r<{ ok: boolean; routerRtpCapabilities?: unknown }>('ms:join');
    if (!joined.ok || !joined.routerRtpCapabilities) throw new Error('Mediasoup admission failed');
    this.joined = true;
    this.check();
    const device = new Device({ handlerName: 'ReactNative106' }) as unknown as NonNullable<NativeMediaSession['device']>;
    await device.load({ routerRtpCapabilities: joined.routerRtpCapabilities });
    this.device = device;
    const extra = this.tcpOnly ? { tcpOnly: true } : {};
    const [so, ro] = await Promise.all([
      this.r<{ ok: boolean; transport?: Record<string, unknown> }>('ms:transport:create', { direction: 'send', ...extra }),
      this.r<{ ok: boolean; transport?: Record<string, unknown> }>('ms:transport:create', { direction: 'recv', ...extra }),
    ]);
    if (!so.ok || !so.transport || !ro.ok || !ro.transport) throw new Error('Mediasoup transport setup failed');
    this.check();
    this.send = device.createSendTransport({ ...so.transport, iceServers: this.iceServers, iceTransportPolicy: 'all' });
    this.recv = device.createRecvTransport({ ...ro.transport, iceServers: this.iceServers, iceTransportPolicy: 'all' });
    this.wire(this.send, 'send');
    this.wire(this.recv, 'recv');
    const track = stream.getAudioTracks()[0];
    this.producer = await this.send.produce({
      track,
      codecOptions: { opusStereo: false, opusDtx: true, opusFec: true, opusMaxPlaybackRate: 48000 },
      encodings: [{ maxBitrate: 48_000, priority: 'high', networkPriority: 'high' } as never],
      appData: { source: 'mic', native: true },
    });
    this.check();
    await this.syncConsumers();
    await waitConnected(this.send);
    this.check();
    this.connected = true;
    this.emit({ state: 'connected' });
  }

  private wire(t: Transport, direction: 'send' | 'recv') {
    t.on('connect', ({ dtlsParameters }: { dtlsParameters: unknown }, cb: () => void, eb: (e: Error) => void) => {
      this.r<{ ok: boolean }>('ms:transport:connect', { direction, transportId: t.id, dtlsParameters })
        .then((x) => (x.ok ? cb() : eb(new Error('Mediasoup DTLS rejected'))))
        .catch(eb);
    });
    if (direction === 'send') {
      t.on('produce', ({ kind, rtpParameters, appData }: Record<string, unknown>, cb: (o: { id: string }) => void, eb: (e: Error) => void) => {
        this.r<{ ok: boolean; id?: string }>('ms:produce', { transportId: t.id, kind, rtpParameters, appData })
          .then((x) => (x.ok && x.id ? cb({ id: x.id }) : eb(new Error('Mediasoup producer rejected'))))
          .catch(eb);
      });
    }
    t.on('connectionstatechange', (state: string) => {
      if (this.closed) return;
      if (state === 'connected') {
        this.iceRestarted.delete(direction);
        if (this.connected) this.emit({ state: 'connected' });
        return;
      }
      if (this.connected && (state === 'disconnected' || state === 'failed') && !this.iceRestarted.has(direction)) {
        this.iceRestarted.add(direction);
        void this.restartIce(t, direction);
        this.emit({ state: 'disconnected' });
        return;
      }
      if (state === 'failed' || state === 'closed') this.emit({ state: 'failed' });
      else if (state === 'disconnected') this.emit({ state: 'disconnected' });
    });
  }

  private async restartIce(t: Transport, direction: string) {
    try {
      const x = await this.r<{ ok: boolean; iceParameters?: unknown }>('ms:transport:restartIce', { direction, transportId: t.id });
      if (x.ok && x.iceParameters && !this.closed) await t.restartIce({ iceParameters: x.iceParameters });
    } catch {}
  }

  async restartIceAll() {
    if (this.send) await this.restartIce(this.send, 'send');
    if (this.recv) await this.restartIce(this.recv, 'recv');
  }

  syncConsumers(): Promise<void> {
    if (this.closed || !this.recv || !this.device) return Promise.resolve();
    if (this.syncing) {
      this.syncAgain = true;
      return this.syncing;
    }
    this.syncing = (async () => {
      try {
        do {
          this.syncAgain = false;
          const x = await this.r<{ ok: boolean; consumers?: Array<Record<string, unknown> & { id: string; kind: string }> }>('ms:consume', {
            transportId: this.recv!.id,
            rtpCapabilities: this.device!.rtpCapabilities,
          });
          if (!x.ok) throw new Error('Mediasoup consumer setup failed');
          for (const p of x.consumers ?? []) {
            // audio-only native mode: remote video stays off (the page shows the avatar)
            if (this.closed || this.consumers.has(p.id) || p.kind !== 'audio') continue;
            const c = await this.recv!.consume(p);
            if (this.closed) { c.close(); continue; }
            this.consumers.set(c.id, c);
            await this.r('ms:consumer:resume', { consumerId: c.id });
            this.emit({ state: 'remote-audio' });
          }
        } while (this.syncAgain && !this.closed);
      } finally {
        this.syncing = null;
      }
    })();
    return this.syncing;
  }

  setMuted(muted: boolean) {
    if (!this.producer) return;
    if (muted) this.producer.pause();
    else this.producer.resume();
    this.stream?.getAudioTracks().forEach((t) => { t.enabled = !muted; });
  }

  async ladder(audioBps: number) {
    const s = this.producer?.rtpSender;
    if (!s) return false;
    try {
      const p = s.getParameters();
      if (!p.encodings?.length) p.encodings = [{}];
      p.encodings.forEach((e: { maxBitrate?: number }) => { e.maxBitrate = audioBps; });
      await s.setParameters(p);
      return true;
    } catch {
      return false;
    }
  }

  /** plain stats objects per transport (the page rebuilds Maps for its quality guard) */
  async stats(): Promise<Array<Array<Record<string, unknown>>>> {
    const out: Array<Array<Record<string, unknown>>> = [];
    for (const t of [this.send, this.recv]) {
      if (!t) continue;
      const m = await t.getStats().catch(() => new Map());
      out.push([...m.values()].map((v) => ({ ...v })));
    }
    return out;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.joined) void this.r('ms:leave').catch(() => {});
    this.joined = false;
    this.consumers.forEach((c) => c.close());
    this.consumers.clear();
    this.producer?.close();
    this.producer = null;
    this.send?.close();
    this.recv?.close();
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
  }
}

function waitConnected(t: Transport): Promise<void> {
  if (t.connectionState === 'connected') return Promise.resolve();
  return new Promise((resolve, reject) => {
    t.on('connectionstatechange', (s: string) => {
      if (s === 'connected') resolve();
      else if (s === 'failed' || s === 'closed') reject(new Error('native transport ' + s));
    });
  });
}

/** Emergency LiveKit (TCP/TURN-443) path, also native: the page never captures the mic in native-media mode. */
class NativeLiveKitSession {
  private room: any = null;
  private stream: MediaStream | null = null;
  private closed = false;
  constructor(readonly callId: string, private emit: Emit) {}
  get alive() {
    return !this.closed;
  }
  async connect(url: string, token: string, iceServers: unknown[]) {
    ensureGlobals();
    const LK = await import('livekit-client');
    const stream = await takeMic();
    if (!stream) throw new Error('microphone unavailable');
    this.stream = stream;
    const room = new LK.Room({ adaptiveStream: false, dynacast: false });
    this.room = room;
    room.on(LK.RoomEvent.Reconnecting, () => this.emit({ state: 'disconnected' }));
    room.on(LK.RoomEvent.Reconnected, () => this.emit({ state: 'connected' }));
    room.on(LK.RoomEvent.Disconnected, () => { if (!this.closed) this.emit({ state: 'failed' }); });
    room.on(LK.RoomEvent.TrackSubscribed, (t: { kind: string }) => { if (t.kind === 'audio') this.emit({ state: 'remote-audio' }); });
    await room.connect(url, token, { autoSubscribe: true, rtcConfig: iceServers.length ? { iceServers: iceServers as RTCIceServer[] } : undefined });
    if (this.closed) throw new Error('native media closed');
    await room.localParticipant.publishTrack(stream.getAudioTracks()[0] as never, { source: LK.Track.Source.Microphone, dtx: true, red: true });
    this.emit({ state: 'connected' });
  }
  setMuted(muted: boolean) {
    this.stream?.getAudioTracks().forEach((t) => { t.enabled = !muted; });
    void this.room?.localParticipant?.setMicrophoneEnabled?.(!muted).catch?.(() => {});
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    void this.room?.disconnect?.();
    this.room = null;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
  }
}

const CALL_ID = /^[A-Za-z0-9_-]{1,64}$/;

/** One live session at a time; owned by App.tsx. Survives WebView reloads (the page re-attaches as UI). */
export class NativeMediaController {
  private session: NativeMediaSession | null = null;
  private lk: NativeLiveKitSession | null = null;
  constructor(private req: Req, private emit: Emit) {}

  /** live call media the app is holding (for a reloaded page to re-attach) */
  current(): { callId: string; kind: 'mediasoup' | 'livekit'; connected: boolean } | null {
    if (this.session?.alive) return { callId: this.session.callId, kind: 'mediasoup', connected: this.session.isConnected };
    if (this.lk?.alive) return { callId: this.lk.callId, kind: 'livekit', connected: true };
    return null;
  }

  async handle(cmd: Record<string, unknown>): Promise<unknown> {
    const callId = typeof cmd.callId === 'string' ? cmd.callId : '';
    switch (cmd.op) {
      case 'prewarm':
        prewarmNativeMedia();
        return true;
      case 'connect': {
        if (!CALL_ID.test(callId)) throw new Error('bad callId');
        const tcpOnly = cmd.tcpOnly === true;
        const cur = this.session;
        // page reload mid-call: same call, same path, still alive → re-attach, never rebuild native media
        if (cur?.alive && cur.callId === callId && cur.tcpOnly === tcpOnly) {
          if (cur.isConnected) {
            void cur.syncConsumers().catch(() => {});
            return { attached: true };
          }
        }
        this.lk?.close();
        this.lk = null;
        cur?.close();
        const s = new NativeMediaSession(callId, Array.isArray(cmd.iceServers) ? cmd.iceServers : [], tcpOnly, this.req, (d) => {
          if (this.session === s) this.emit(d);
        });
        this.session = s;
        try {
          await s.connect();
        } catch (e) {
          if (this.session === s) { s.close(); this.session = null; }
          throw e;
        }
        return { attached: false };
      }
      case 'connectLiveKit': {
        if (!CALL_ID.test(callId) || typeof cmd.url !== 'string' || typeof cmd.token !== 'string') throw new Error('bad livekit media');
        if (this.lk?.alive && this.lk.callId === callId) return { attached: true };
        this.session?.close();
        this.session = null;
        this.lk?.close();
        const l = new NativeLiveKitSession(callId, (d) => { if (this.lk === l) this.emit(d); });
        this.lk = l;
        try {
          await l.connect(cmd.url, cmd.token, Array.isArray(cmd.iceServers) ? cmd.iceServers : []);
        } catch (e) {
          if (this.lk === l) { l.close(); this.lk = null; }
          throw e;
        }
        return { attached: false };
      }
      case 'status':
        return this.current();
      case 'consumerAvailable':
        await this.session?.syncConsumers().catch(() => {});
        return true;
      case 'mute':
        this.session?.setMuted(cmd.muted === true);
        this.lk?.setMuted(cmd.muted === true);
        return true;
      case 'restartIce':
        await this.session?.restartIceAll();
        return true;
      case 'ladder':
        return (await this.session?.ladder(Number(cmd.audioBps) || 48_000)) ?? false;
      case 'stats':
        return (await this.session?.stats()) ?? [];
      case 'close':
        this.closeAll(false);
        return true;
    }
    throw new Error('unknown op');
  }

  /** Network path changed (Wi-Fi ⇄ cellular): fresh ICE in place, natively — no page involvement needed. */
  onNetworkChange() {
    void this.session?.restartIceAll().catch(() => {});
  }

  closeAll(dropPrewarm = true) {
    this.session?.close();
    this.session = null;
    this.lk?.close();
    this.lk = null;
    if (dropPrewarm) {
      preStream?.then((st) => st?.getTracks().forEach((t) => t.stop()));
      preStream = null;
    }
  }
}
