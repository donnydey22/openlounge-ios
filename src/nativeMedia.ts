// Native call media (iOS): the app, not the WebView, owns the microphone, the mediasoup send/recv transports and
// the AVAudioSession (CallKit-driven, see OLCallManager.swift: RTCAudioSession.useManualAudio + isAudioEnabled on
// didActivate). The web page stays the call UI + signaling: it relays every ms:* request over its authenticated
// realtime socket (window.__olNativeMsReq) and forwards ms:consumer:available here.
//
// Page → app  (bridge method 'nativeMedia', request/reply):
//   {op:'prepare', callId, ...}              ring-time client/SFU preparation only; no getUserMedia
//   {op:'connect', callId, iceServers, video?, nativeVideo?, tcpOnly?, rebuild?} join + send/recv transports + paired native producers
//   {op:'connectLiveKit', callId, url, token, iceServers, video?, nativeVideo?, streamId?} native fallback on one participant
//   {op:'status'}  → {callId, kind, connected} | null    (a reloaded page re-attaches; connect on the same call = attach)
//   {op:'mute', muted} | {op:'close'} | {op:'restartIce'} | {op:'stats'} | {op:'ladder', audioBps, videoBps?, videoFps?, videoScale?}
//   {op:'consumerAvailable'}  SFU remote-track availability arrived on the page socket
// App → page events (CustomEvent 'openlounge:native-media'): {state:'connected'|'disconnected'|'failed'|'remote-audio'|'remote-video', on?:boolean}
// App-only video state is delivered directly to App.tsx; MediaStream values are never serialized into the WebView.
import { mediaDevices, MediaStream, type MediaStreamTrack } from '@livekit/react-native-webrtc';
import { registerGlobals } from '@livekit/react-native';

type Req = <T>(event: string, data: Record<string, unknown>) => Promise<T>;
type Emit = (detail: Record<string, unknown>) => void;

let globalsDone = false;
function ensureGlobals() {
  if (globalsDone) return;
  registerGlobals();
  globalsDone = true;
}

/** Native camera constraints preserve an upright 720p-class sensor frame at 30 fps. RTCView renders the full-screen
 * remote tile with aspect fill and the local tile with aspect fill, matching the existing phone call UI without
 * stretching either source. Capture exposure remains AVFoundation's native automatic exposure. */
const cameraConstraints = (facing: 'user' | 'environment' = 'user') => ({
  facingMode: facing,
  width: { ideal: 720 },
  height: { ideal: 1280 },
  frameRate: { ideal: 30, max: 30 },
} as never);
/** Capture happens only when the native connection starts after CallKit activation; preparation is media-free. */
async function takeStream(video: boolean): Promise<MediaStream | null> {
  ensureGlobals();
  const paired = (await mediaDevices.getUserMedia({ audio: true, video: video ? cameraConstraints() : false }).catch(() => null)) as MediaStream | null;
  if (paired || !video) return paired;
  return (await mediaDevices.getUserMedia({ audio: true, video: false }).catch(() => null)) as MediaStream | null;
}
export type NativeVideoState = { callId: string; local: MediaStream | null; remote: MediaStream | null; facing: 'user' | 'environment' } | null;
type NativeCapture = { callId: string; stream: MediaStream; nativeVideo: boolean; streamId: string | null; facing: 'user' | 'environment' };
type PreparedNative = { callId: string; nativeVideo: boolean; streamId: string | null; nativeConn: string; device: any; joined: boolean };
const nativeConnectionId = () => `n_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;

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
type Producer = { id: string; pause(): void; resume(): void; close(): void; replaceTrack?(o: { track: MediaStreamTrack }): Promise<void>; rtpSender?: { getParameters(): any; setParameters(p: any): Promise<void> } };
type Consumer = { id: string; kind: string; track: MediaStreamTrack; close(): void };
type NativeQualityStep = { audioBps: number; videoBps?: number; videoFps?: number; videoScale?: number };
type VideoCodecCapability = { kind?: string; mimeType?: string; parameters?: Record<string, unknown> };
type SenderEncoding = { maxBitrate?: number; maxFramerate?: number; scaleResolutionDownBy?: number };
const NATIVE_CAMERA_MAX_BPS = 850_000;

/**
 * The SFU does not expose a peer receiver's RTP capabilities before this producer is created. VP8 is therefore the
 * proven interoperable baseline; selecting H.264 from this device/router intersection would incorrectly assume that
 * Keiko's Android consumer supports the same profile. A future negotiated peer-capability signal may opt into H.264.
 */
function preferredVP8(rtpCapabilities: unknown): VideoCodecCapability | undefined {
  const codecs = (rtpCapabilities as { codecs?: unknown } | null)?.codecs;
  if (!Array.isArray(codecs)) return undefined;
  return codecs.find((candidate): candidate is VideoCodecCapability =>
    !!candidate && typeof candidate === 'object' && (candidate as VideoCodecCapability).kind === 'video' && (candidate as VideoCodecCapability).mimeType?.toLowerCase() === 'video/vp8',
  );
}

const CONNECT_TIMEOUT_MS = 12_000;

export class NativeMediaSession {
  private send: Transport | null = null;
  private recv: Transport | null = null;
  private device: { rtpCapabilities: unknown; load(o: unknown): Promise<void>; createSendTransport(o: unknown): Transport; createRecvTransport(o: unknown): Transport } | null = null;
  private producer: Producer | null = null;
  private videoProducer: Producer | null = null;
  private localVideo: MediaStream | null = null;
  private remoteVideo: MediaStream | null = null;
  private facing: 'user' | 'environment' = 'user';
  private consumers = new Map<string, Consumer>();
  private closed = false;
  private joined = false;
  private connected = false;
  private syncing: Promise<void> | null = null;
  private syncAgain = false;
  private iceRestarted = new Set<string>();
  /** At most one native setParameters transaction runs at a time; latest sample wins while it is in flight. */
  private ladderTask: Promise<boolean> | null = null;
  private pendingLadder: NativeQualityStep | null = null;
  /** rejects the moment close() runs, so a superseded connect never sits on a dead transport until the timeout */
  private abortRej: ((e: Error) => void) | null = null;
  private aborted = new Promise<never>((_, rej) => { this.abortRej = rej; });

  /** stable server-side connection id for this media session: a page reload (new socket) re-attaches to it instead
   *  of the server tearing the SFU peer down with the old socket */
  constructor(readonly callId: string, private iceServers: unknown[], readonly tcpOnly: boolean, private relayOnly: boolean, readonly nativeVideo: boolean, private streamId: string | null, private stream: MediaStream, private capture: NativeCapture, readonly nativeConn: string, private prepared: PreparedNative | null, private req: Req, private emit: Emit, private emitVideo: (state: NativeVideoState) => void) {}

  get alive() {
    return !this.closed;
  }
  get isConnected() {
    return this.connected && !this.closed;
  }

  /** Re-assert app-owned renderer state when a reloaded WebView re-attaches to this live native session. */
  replayVideoState() {
    if (!this.nativeVideo) return;
    this.emitVideoState();
    this.emit({ state: 'remote-video', callId: this.callId, on: !!this.remoteVideo });
  }

  private r<T>(event: string, data: Record<string, unknown> = {}) {
    return this.req<T>(event, { callId: this.callId, nativeConn: this.nativeConn, ...data });
  }

  async connect(): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | null = null;
    try {
      await Promise.race([
        this.connectInner(),
        this.aborted,
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
    const { Device } = await import('mediasoup-client');
    const stream = this.stream;
    this.check();
    const prepared = this.prepared;
    // Every fresh transport pair re-attaches to the broker under the same native connection id. The prepared Device
    // remains valid, but close() deliberately sent ms:leave for the old pair, so reuse never skips this admission.
    const joined = await this.r<{ ok: boolean; routerRtpCapabilities?: unknown }>('ms:join');
    if (!joined.ok || !joined.routerRtpCapabilities) throw new Error('Mediasoup admission failed');
    this.joined = true;
    let device = prepared?.device as NonNullable<NativeMediaSession['device']> | undefined;
    if (!device) {
      device = new Device({ handlerName: 'ReactNative106' }) as unknown as NonNullable<NativeMediaSession['device']>;
      await device.load({ routerRtpCapabilities: joined.routerRtpCapabilities });
    }
    this.check();
    this.device = device;
    const extra = this.tcpOnly ? { tcpOnly: true } : {};
    const [so, ro] = await Promise.all([
      this.r<{ ok: boolean; transport?: Record<string, unknown> }>('ms:transport:create', { direction: 'send', ...extra }),
      this.r<{ ok: boolean; transport?: Record<string, unknown> }>('ms:transport:create', { direction: 'recv', ...extra }),
    ]);
    if (!so.ok || !so.transport || !ro.ok || !ro.transport) throw new Error('Mediasoup transport setup failed');
    this.check();
    this.send = device.createSendTransport({ ...so.transport, iceServers: this.iceServers, iceTransportPolicy: this.relayOnly ? 'relay' : 'all' });
    this.recv = device.createRecvTransport({ ...ro.transport, iceServers: this.iceServers, iceTransportPolicy: this.relayOnly ? 'relay' : 'all' });
    this.wire(this.send, 'send');
    this.wire(this.recv, 'recv');
    const track = stream.getAudioTracks()[0];
    this.producer = await this.send.produce({
      track,
      codecOptions: { opusStereo: false, opusDtx: false, // DTX off: onset clipping read as quiet (web parity, Oct 16)
        opusFec: true, opusMaxPlaybackRate: 48000 },
      encodings: [{ maxBitrate: 48_000, priority: 'high', networkPriority: 'high' } as never],
      ...(this.streamId ? { streamId: this.streamId } : {}),
      appData: { source: 'mic', native: true },
    });
    if (this.nativeVideo) {
      try {
        await this.publishCamera(stream.getVideoTracks()[0]);
      } catch {
        // Mic production already succeeded: keep the call up and let the page mark its camera unavailable.
        this.emit({ state: 'camera-unavailable' });
      }
    }
    this.check();
    await this.syncConsumers();
    await waitConnected(this.send);
    this.check();
    this.connected = true;
    this.emit({ state: 'connected' });
  }

  private emitVideoState() {
    this.emitVideo(this.closed ? null : { callId: this.callId, local: this.localVideo, remote: this.remoteVideo, facing: this.facing });
  }
  private async publishCamera(track: MediaStreamTrack | undefined) {
    if (!track || !this.send) throw new Error('camera unavailable');
    this.localVideo = null;
    const local = new MediaStream([track]);
    this.localVideo = local;
    const options = {
      track,
      ...(this.streamId ? { streamId: this.streamId } : {}),
      // One proven VP8 encoding. The quality ladder adapts this sender in place (bitrate, resolution and fps) without
      // reacquiring the camera or multiplying the video budget across simulcast layers.
      encodings: [{ maxBitrate: NATIVE_CAMERA_MAX_BPS, maxFramerate: 30, scaleResolutionDownBy: 1, priority: 'high', networkPriority: 'high' }] as never,
      appData: { source: 'camera', native: true },
    };
    try {
      const vp8 = preferredVP8(this.device?.rtpCapabilities);
      if (!vp8) throw new Error('VP8 unavailable');
      this.videoProducer = await this.send.produce({ ...options, codec: vp8 });
      this.emitVideoState();
    } catch (error) {
      if (this.localVideo === local) this.localVideo = null;
      // `local` references the controller-owned capture track. Stop only the failed camera, never its paired mic.
      this.capture.stream.removeTrack(track);
      track.stop();
      this.emitVideoState();
      throw error;
    }
  }
  private async acquireCamera(facing: 'user' | 'environment') {
    ensureGlobals();
    const stream = (await mediaDevices.getUserMedia({ audio: false, video: cameraConstraints(facing) })) as MediaStream;
    const track = stream.getVideoTracks()[0];
    if (!track) { stream.getTracks().forEach((t) => t.stop()); throw new Error('camera unavailable'); }
    for (const prior of this.capture.stream.getVideoTracks()) { this.capture.stream.removeTrack(prior); prior.stop(); }
    this.capture.stream.addTrack(track);
    this.capture.facing = facing;
    this.facing = facing;
    return { stream: this.capture.stream, track };
  }
  async setCamera(on: boolean, facing: 'user' | 'environment' = this.facing): Promise<boolean> {
    if (this.closed) throw new Error('native media closed');
    if (!this.nativeVideo) return false;
    if (!on) {
      this.videoProducer?.close();
      this.videoProducer = null;
      for (const track of this.capture.stream.getVideoTracks()) { this.capture.stream.removeTrack(track); track.stop(); }
      this.localVideo = null;
      this.emitVideoState();
      return true;
    }
    if (!this.send) throw new Error('native media not connected');
    const next = await this.acquireCamera(facing);
    try {
      if (this.videoProducer?.replaceTrack) {
        await this.videoProducer.replaceTrack({ track: next.track });
        this.localVideo = next.stream;
        this.emitVideoState();
      } else {
        this.videoProducer?.close();
        this.videoProducer = null;
        this.localVideo = null;
        await this.publishCamera(next.track);
      }
    } catch (error) {
      // `next.stream` is the paired controller-owned stream. A failed flip must not stop the microphone.
      this.capture.stream.removeTrack(next.track);
      next.track.stop();
      this.localVideo = null;
      this.emitVideoState();
      throw error;
    }
    return true;
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
      if (this.connected && (state === 'disconnected' || state === 'failed')) {
        // persistent reconnecting: keep restarting ICE with backoff for as long as the call lives (the page/server
        // decide when it ends). The page also gets 'disconnected' → "Reconnecting…" and may step down the ladder.
        this.emit({ state: 'disconnected' });
        if (!this.iceRestarted.has(direction)) {
          this.iceRestarted.add(direction);
          void this.keepRestarting(t, direction);
        }
        if (state === 'failed') this.emit({ state: 'failed' });
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

  private async keepRestarting(t: Transport, direction: string) {
    const delays = [0, 500, 1000, 2000, 4000]; // back on UDP sooner (web parity, Oct 16)
    for (let i = 0; !this.closed && this.iceRestarted.has(direction); i++) {
      await new Promise((r) => setTimeout(r, delays[Math.min(i, delays.length - 1)]));
      if (this.closed || !this.iceRestarted.has(direction) || t.connectionState === 'connected') return;
      await this.restartIce(t, direction);
    }
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
            // A native-video grant consumes the matching video producer on this same connection; audio-only calls stay unchanged.
            if (this.closed || this.consumers.has(p.id) || (p.kind !== 'audio' && (!this.nativeVideo || p.kind !== 'video'))) continue;
            const c = await this.recv!.consume(p);
            if (this.closed) { c.close(); continue; }
            if (c.kind === 'video' && this.nativeVideo) {
              // A replacement producer must not retain an old, detached video Consumer on the recv transport.
              for (const [id, prior] of this.consumers) {
                if (prior.kind === 'video') { prior.close(); this.consumers.delete(id); }
              }
              // Replace the native renderer stream before stopping the old track. Its ended callback then sees it is
              // stale and cannot transiently clear the remote-video UI state during a producer replacement.
              const previousRemote = this.remoteVideo;
              this.remoteVideo = new MediaStream([c.track]);
              previousRemote?.getTracks().forEach((t) => t.stop());
              c.track.addEventListener('ended', () => {
                if (!this.remoteVideo?.getVideoTracks().some((track) => track === c.track)) return;
                this.remoteVideo?.getTracks().forEach((track) => track.stop());
                this.remoteVideo = null;
                this.emitVideoState();
                // Control state only: the page uses this to choose remote-full/local-PiP geometry. Streams stay native.
                this.emit({ state: 'remote-video', callId: this.callId, on: false });
              }, { once: true });
            }
            this.consumers.set(c.id, c);
            await this.r('ms:consumer:resume', { consumerId: c.id });
            if (c.kind === 'audio') this.emit({ state: 'remote-audio' });
            else if (this.nativeVideo) {
              this.emitVideoState();
              // The WebView cannot inspect the native track. It receives only availability so its existing overlay
              // selects the remote full-screen tile and local PiP; App.tsx keeps both MediaStreams native.
              this.emit({ state: 'remote-video', callId: this.callId, on: true });
            }
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

  /** Apply one sender's parameters without replacing a track or reopening either native capture device. */
  private async setSenderParameters(producer: Producer | null, update: (encoding: SenderEncoding, index: number) => void) {
    const sender = producer?.rtpSender;
    if (!sender) return !producer;
    const parameters = sender.getParameters();
    if (!parameters.encodings?.length) parameters.encodings = [{}];
    parameters.encodings.forEach((encoding: SenderEncoding, index: number) => update(encoding, index));
    await sender.setParameters(parameters);
    return true;
  }

  /** Coalesce the one-second page samples: native WebRTC rejects overlapping setParameters transactions. */
  async ladder(step: NativeQualityStep) {
    if (this.closed) return false;
    this.pendingLadder = {
      // The shared ladder reserves the 16 kbps Opus floor before camera bitrate. Do not reintroduce a local 24/60 kbps
      // clamp here: it would oversubscribe the weakest native link the page has already measured.
      audioBps: Math.max(16_000, Math.round(step.audioBps || 48_000)),
      ...(Number.isFinite(step.videoBps) ? { videoBps: Math.min(NATIVE_CAMERA_MAX_BPS, Math.max(1_000, Math.round(step.videoBps!))) } : {}),
      ...(Number.isFinite(step.videoFps) ? { videoFps: Math.max(8, Math.min(30, Math.round(step.videoFps!))) } : {}),
      ...(Number.isFinite(step.videoScale) ? { videoScale: Math.max(1, Math.min(4, Number(step.videoScale))) } : {}),
    };
    if (this.ladderTask) return this.ladderTask;
    this.ladderTask = (async () => {
      let applied = false;
      while (!this.closed && this.pendingLadder) {
        const next = this.pendingLadder;
        this.pendingLadder = null;
        try {
          const audio = await this.setSenderParameters(this.producer, (encoding) => { encoding.maxBitrate = next.audioBps; });
          const video = await this.setSenderParameters(this.videoProducer, (encoding) => {
            if (next.videoBps !== undefined) encoding.maxBitrate = next.videoBps;
            if (next.videoFps !== undefined) encoding.maxFramerate = next.videoFps;
            if (next.videoScale !== undefined) encoding.scaleResolutionDownBy = next.videoScale;
          });
          applied = audio && video;
        } catch {
          applied = false;
        }
      }
      return applied;
    })().finally(() => { this.ladderTask = null; });
    return this.ladderTask;
  }

  /** plain stats objects per transport (the page rebuilds Maps for its quality guard) */
  async stats(): Promise<Array<Array<Record<string, unknown>>>> {
    const out: Array<Array<Record<string, unknown>>> = [];
    for (const [direction, t] of [['send', this.send], ['recv', this.recv]] as const) {
      if (!t) continue;
      const m = await t.getStats().catch(() => new Map());
      // `availableOutgoingBitrate` belongs to the send transport. Preserve the marker internally so the page does
      // not take the minimum of two unrelated candidate-pair estimates and pin the native camera around 300 kbps.
      out.push([...m.values()].map((v) => ({ ...v, __olTransportDirection: direction })));
    }
    return out;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.pendingLadder = null;
    this.aborted.catch(() => {});
    this.abortRej?.(new Error('native media closed'));
    if (this.joined) void this.r('ms:leave').catch(() => {});
    this.joined = false;
    this.consumers.forEach((c) => c.close());
    this.consumers.clear();
    this.producer?.close();
    this.producer = null;
    this.videoProducer?.close();
    this.videoProducer = null;
    this.localVideo = null;
    const hadRemoteVideo = !!this.remoteVideo;
    this.remoteVideo?.getTracks().forEach((t) => t.stop());
    this.remoteVideo = null;
    this.emitVideoState();
    if (hadRemoteVideo) this.emit({ state: 'remote-video', callId: this.callId, on: false });
    this.send?.close();
    this.recv?.close();
    // The controller owns capture across native rebuilds and LiveKit migration; terminal closeAll stops it.
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

/** Emergency LiveKit keeps the same app-owned capture and publishes mic+camera on one participant for a latched call. */
class NativeLiveKitSession {
  private room: any = null;
  private closed = false;
  private localVideo: MediaStream | null = null;
  private remoteVideo: MediaStream | null = null;
  private remoteTrack: MediaStreamTrack | null = null;
  private videoTrack: MediaStreamTrack | null = null;
  constructor(readonly callId: string, private capture: NativeCapture, private emit: Emit, private emitVideo: (state: NativeVideoState) => void) {}
  get alive() { return !this.closed; }
  private state() { this.emitVideo(this.closed ? null : { callId: this.callId, local: this.localVideo, remote: this.remoteVideo, facing: this.capture.facing }); }
  private clearRemoteVideo(track?: MediaStreamTrack) {
    // A late unsubscribe from a replaced subscription must not clear the current remote full-screen stream.
    if (track && track !== this.remoteTrack) return;
    if (!this.remoteTrack && !this.remoteVideo) return;
    this.remoteTrack = null;
    this.remoteVideo = null;
    this.state();
    this.emit({ state: 'remote-video', callId: this.callId, on: false });
  }
  replayVideoState() {
    if (!this.capture.nativeVideo) return;
    this.state();
    this.emit({ state: 'remote-video', callId: this.callId, on: !!this.remoteVideo });
  }
  async connect(url: string, token: string, iceServers: unknown[]) {
    ensureGlobals();
    const LK = await import('livekit-client');
    const stream = this.capture.stream;
    const room = new LK.Room({ adaptiveStream: false, dynacast: false });
    this.room = room;
    room.on(LK.RoomEvent.Reconnecting, () => this.emit({ state: 'disconnected' }));
    room.on(LK.RoomEvent.Reconnected, () => this.emit({ state: 'connected' }));
    room.on(LK.RoomEvent.Disconnected, () => { if (!this.closed) this.emit({ state: 'failed' }); });
    room.on(LK.RoomEvent.TrackSubscribed, (t: any) => {
      if (t.kind === 'audio') this.emit({ state: 'remote-audio' });
      else if (t.kind === 'video' && this.capture.nativeVideo) {
        const track = t.mediaStreamTrack as MediaStreamTrack | undefined;
        if (!track) return;
        this.remoteTrack = track;
        this.remoteVideo = new MediaStream([track]);
        track.addEventListener('ended', () => this.clearRemoteVideo(track), { once: true });
        this.state();
        this.emit({ state: 'remote-video', callId: this.callId, on: true });
      }
    });
    room.on(LK.RoomEvent.TrackUnsubscribed, (t: any) => {
      if (t.kind === 'video') this.clearRemoteVideo(t.mediaStreamTrack as MediaStreamTrack | undefined);
    });
    await room.connect(url, token, { autoSubscribe: true, rtcConfig: iceServers.length ? { iceServers: iceServers as RTCIceServer[] } : undefined });
    if (this.closed) throw new Error('native media closed');
    const mic = stream.getAudioTracks()[0];
    if (!mic) throw new Error('microphone unavailable');
    await room.localParticipant.publishTrack(mic as never, { source: LK.Track.Source.Microphone, dtx: true, red: true });
    if (this.capture.nativeVideo) await this.publishCamera(LK, stream.getVideoTracks()[0]);
    this.emit({ state: 'connected' });
  }
  private async publishCamera(LK: any, track: MediaStreamTrack | undefined) {
    if (!track) { this.emit({ state: 'camera-unavailable' }); return; }
    // Keep TCP fallback on the same proven single VP8 sender plan as direct media. Do not infer a peer-compatible
    // H.264 profile from local/router capabilities; LiveKit negotiates VP8 with the receiver as the safe baseline.
    await this.room.localParticipant.publishTrack(track as never, {
      source: LK.Track.Source.Camera,
      simulcast: false,
      videoCodec: 'vp8',
      videoEncoding: { maxBitrate: NATIVE_CAMERA_MAX_BPS, maxFramerate: 30 },
    } as never);
    this.videoTrack = track; this.localVideo = new MediaStream([track]); this.state();
  }
  async setCamera(on: boolean, facing: 'user' | 'environment') {
    if (!this.capture.nativeVideo || !this.room) return false;
    if (!on) { if (this.videoTrack) await this.room.localParticipant.unpublishTrack(this.videoTrack as never, false); for (const track of this.capture.stream.getVideoTracks()) { this.capture.stream.removeTrack(track); track.stop(); } this.videoTrack = null; this.localVideo = null; this.state(); return true; }
    const next = (await mediaDevices.getUserMedia({ audio: false, video: cameraConstraints(facing) })) as MediaStream;
    const track = next.getVideoTracks()[0]; if (!track) throw new Error('camera unavailable');
    if (this.videoTrack) await this.room.localParticipant.unpublishTrack(this.videoTrack as never, false);
    for (const prior of this.capture.stream.getVideoTracks()) { this.capture.stream.removeTrack(prior); prior.stop(); }
    this.capture.stream.addTrack(track); this.capture.facing = facing;
    const LK = await import('livekit-client'); await this.publishCamera(LK, track); return true;
  }
  setMuted(muted: boolean) { this.capture.stream.getAudioTracks().forEach((t) => { t.enabled = !muted; }); }
  close() {
    if (this.closed) return;
    this.closed = true;
    const hadRemoteVideo = !!this.remoteVideo;
    void this.room?.disconnect?.();
    this.room = null;
    this.localVideo = null;
    this.remoteVideo = null;
    this.remoteTrack = null;
    this.emitVideo(null);
    if (hadRemoteVideo) this.emit({ state: 'remote-video', callId: this.callId, on: false });
  }
}
const CALL_ID = /^[A-Za-z0-9_-]{1,64}$/;
const STREAM_ID = /^[A-Za-z0-9:_-]{1,160}$/;

/** One live session at a time; owned by App.tsx. Survives WebView reloads (the page re-attaches as UI). */
export class NativeMediaController {
  private session: NativeMediaSession | null = null;
  private lk: NativeLiveKitSession | null = null;
  private capture: NativeCapture | null = null;
  private prepared: PreparedNative | null = null;
  /** the one fresh build in flight: a second connect for the same call/path joins it instead of tearing it down
   *  (the 60 s block hang: recovery + the page's own rejoin both issued connect, each closing the other's session) */
  private building: { callId: string; tcpOnly: boolean; p: Promise<{ attached: boolean }>; tok: object } | null = null;
  constructor(private req: Req, private emit: Emit, private emitVideo: (state: NativeVideoState) => void) {}

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
        // Compatibility no-op: capture is intentionally deferred until connect/answer.
        return true;
      case 'prepare': {
        if (!CALL_ID.test(callId)) throw new Error('bad callId');
        const nativeVideo = cmd.video === true && cmd.nativeVideo === true;
        const streamId = nativeVideo && typeof cmd.streamId === 'string' && STREAM_ID.test(cmd.streamId) ? cmd.streamId : null;
        const { Device } = await import('mediasoup-client');
        void import('livekit-client').catch(() => {});
        const nativeConn = this.prepared?.callId === callId ? this.prepared.nativeConn : nativeConnectionId();
        const joined = await this.req<{ ok: boolean; routerRtpCapabilities?: unknown }>('ms:join', { callId, nativeConn });
        if (!joined.ok || !joined.routerRtpCapabilities) throw new Error('Mediasoup admission failed');
        const device = new Device({ handlerName: 'ReactNative106' });
        await device.load({ routerRtpCapabilities: joined.routerRtpCapabilities });
        this.prepared = { callId, nativeVideo, streamId, nativeConn, device, joined: true };
        return true;
      }
      case 'connect': {
        if (!CALL_ID.test(callId)) throw new Error('bad callId');
        const tcpOnly = cmd.tcpOnly === true;
        const relayOnly = cmd.relayOnly === true;
        // outage recovery: the page asks for fresh transports (its ICE restarts did not bring the media back)
        const rebuild = cmd.rebuild === true;
        const cur = this.session;
        // page reload mid-call: same call, same path, still alive → re-attach, never rebuild native media
        if (!rebuild && cur?.alive && cur.callId === callId && cur.tcpOnly === tcpOnly) {
          if (cur.isConnected) {
            void cur.syncConsumers().catch(() => {});
            cur.replayVideoState();
            return { attached: true };
          }
        }
        const b = this.building;
        if (b && b.callId === callId && b.tcpOnly === tcpOnly) return b.p;
        this.lk?.close();
        this.lk = null;
        cur?.close();
        const requestedVideo = cmd.video === true && cmd.nativeVideo === true;
        const existing = this.capture?.callId === callId ? this.capture : null;
        const nativeVideo = existing?.nativeVideo ?? requestedVideo;
        const streamId = existing?.streamId ?? (nativeVideo && typeof cmd.streamId === 'string' && STREAM_ID.test(cmd.streamId) ? cmd.streamId : null);
        const capture = existing ?? (() => null)();
        const stream = capture?.stream ?? await takeStream(nativeVideo);
        if (!stream) throw new Error('microphone unavailable');
        this.capture = capture ?? { callId, stream, nativeVideo, streamId, facing: 'user' };
        const prepared = this.prepared?.callId === callId ? this.prepared : null;
        const nativeConn = prepared?.nativeConn ?? nativeConnectionId();
        const s = new NativeMediaSession(callId, Array.isArray(cmd.iceServers) ? cmd.iceServers : [], tcpOnly, relayOnly, nativeVideo, streamId, this.capture.stream, this.capture, nativeConn, prepared, this.req, (d) => {
          if (this.session === s) this.emit(d);
        }, (state) => {
          if (this.session === s) this.emitVideo(state);
        });
        this.session = s;
        const tok = {};
        const p = (async () => {
          try {
            await s.connect();
            return { attached: false };
          } catch (e) {
            if (this.session === s) { s.close(); this.session = null; }
            throw e;
          } finally {
            if (this.building?.tok === tok) this.building = null;
          }
        })();
        this.building = { callId, tcpOnly, p, tok };
        return p;
      }
      case 'connectLiveKit': {
        if (!CALL_ID.test(callId) || typeof cmd.url !== 'string' || typeof cmd.token !== 'string') throw new Error('bad livekit media');
        if (this.lk?.alive && this.lk.callId === callId) {
          this.lk.replayVideoState();
          return { attached: true };
        }
        this.session?.close();
        this.session = null;
        this.lk?.close();
        const existing = this.capture?.callId === callId ? this.capture : null;
        const nativeVideo = existing?.nativeVideo ?? (cmd.video === true && cmd.nativeVideo === true);
        const streamId = existing?.streamId ?? (nativeVideo && typeof cmd.streamId === 'string' && STREAM_ID.test(cmd.streamId) ? cmd.streamId : null);
        const stream = existing?.stream ?? await takeStream(nativeVideo);
        if (!stream) throw new Error('microphone unavailable');
        this.capture = existing ?? { callId, stream, nativeVideo, streamId, facing: 'user' };
        const l = new NativeLiveKitSession(callId, this.capture, (d) => { if (this.lk === l) this.emit(d); }, (state) => { if (this.lk === l) this.emitVideo(state); });
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
        return (await this.session?.ladder({
          audioBps: Number(cmd.audioBps) || 48_000,
          ...(typeof cmd.videoBps === 'number' ? { videoBps: cmd.videoBps } : {}),
          ...(typeof cmd.videoFps === 'number' ? { videoFps: cmd.videoFps } : {}),
          ...(typeof cmd.videoScale === 'number' ? { videoScale: cmd.videoScale } : {}),
        })) ?? false;
      case 'stats':
        return (await this.session?.stats()) ?? [];
      case 'camera': {
        const facing = cmd.facing === 'environment' ? 'environment' : 'user';
        return (await this.session?.setCamera(cmd.on === true, facing) ?? this.lk?.setCamera(cmd.on === true, facing)) ?? false;
      }
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
    this.building = null;
    this.session?.close();
    this.session = null;
    this.lk?.close();
    this.lk = null;
    this.emitVideo(null);
    if (dropPrewarm) {
      this.capture?.stream.getTracks().forEach((t) => t.stop());
      this.capture = null;
      this.prepared = null;

    }
  }
}
