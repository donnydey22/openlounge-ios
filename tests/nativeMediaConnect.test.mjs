// Behaviour test for the native reconnect path: concurrent connects coalesce, a superseded connect aborts promptly,
// and static assertions protect the paired iPhone audio+camera contract.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import ts from 'typescript';

const source = () => readFileSync('src/nativeMedia.ts', 'utf8');
const dir = mkdtempSync(join(tmpdir(), 'nm-'));
let js = ts.transpileModule(source(), { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
js = js.replace(/import \{[^}]*\} from '@livekit\/react-native-webrtc';/, 'const mediaDevices = globalThis.__md;')
  .replace(/import \{[^}]*\} from '@livekit\/react-native';/, 'const registerGlobals = () => {};')
  .replace(/import\('mediasoup-client'\)/g, 'Promise.resolve(globalThis.__ms)');
writeFileSync(join(dir, 'nm.mjs'), js);

const track = () => ({ readyState: 'live', enabled: true, stop() { this.readyState = 'ended'; } });
globalThis.__md = { getUserMedia: async () => { const t = track(); return { getAudioTracks: () => [t], getVideoTracks: () => [], getTracks: () => [t] }; } };
let transports = [];
function mkT(dir) {
  const h = {}; const t = { id: dir + transports.length, connectionState: 'new', on: (e, f) => ((h[e] ||= []).push(f)),
    fire: (s) => { t.connectionState = s; (h.connectionstatechange || []).forEach((f) => f(s)); },
    produce: async (o) => ({ id: 'p', options: o, close() {}, pause() {}, resume() {} }), consume: async (p) => ({ id: p.id, kind: 'audio', close() {} }),
    restartIce: async () => {}, getStats: async () => new Map(), close() { t.fire('closed'); } };
  transports.push(t); return t;
}
globalThis.__ms = { Device: class { rtpCapabilities = {}; async load() {} createSendTransport() { return mkT('s'); } createRecvTransport() { return mkT('r'); } } };
const { NativeMediaController } = await import(join(dir, 'nm.mjs'));
const tick = () => new Promise((r) => setTimeout(r, 5));
let joins = 0;
const req = async (ev) => { if (ev === 'ms:join') { joins++; return { ok: true, routerRtpCapabilities: {} }; }
  if (ev === 'ms:transport:create') return { ok: true, transport: {} }; if (ev === 'ms:consume') return { ok: true, consumers: [] }; return { ok: true }; };

test('two concurrent rebuild connects coalesce into one fresh build', async () => {
  transports = []; joins = 0;
  const c = new NativeMediaController(req, () => {}, () => {});
  const a = c.handle({ op: 'connect', callId: 'c1', rebuild: true });
  const b = c.handle({ op: 'connect', callId: 'c1', rebuild: true });
  await tick(); transports.filter((t) => t.id.startsWith('s')).forEach((t) => t.fire('connected'));
  const [ra, rb] = await Promise.all([a, b]);
  assert.deepEqual(ra, { attached: false }); assert.equal(ra, rb); assert.equal(joins, 1);
  assert.equal(c.current().connected, true);
  c.closeAll();
});
test('a superseded connect (path change) fails fast instead of hanging to the timeout', async () => {
  transports = [];
  const c = new NativeMediaController(req, () => {}, () => {});
  const t0 = Date.now();
  const a = c.handle({ op: 'connect', callId: 'c2' }).then(() => 'ok', (e) => e.message);
  await tick();
  const b = c.handle({ op: 'connect', callId: 'c2', tcpOnly: true });
  assert.equal(await a, 'native media closed'); assert.ok(Date.now() - t0 < 2000);
  await tick(); transports.at(-2).fire('connected');
  assert.deepEqual(await b, { attached: false });
  c.closeAll();
});
test('after a build settles, a later rebuild builds fresh again', async () => {
  transports = []; joins = 0;
  const c = new NativeMediaController(req, () => {}, () => {});
  const go = async () => { const p = c.handle({ op: 'connect', callId: 'c3', rebuild: true }); await tick(); transports.at(-2).fire('connected'); return p; };
  await go(); await go(); assert.equal(joins, 2); c.closeAll();
});

test('paired native producers use one app-owned stream and an explicit shared stream identifier', () => {
  const src = source();
  assert.match(src, /const \[\{ Device \}, stream\] = await Promise\.all\(\[import\('mediasoup-client'\), takeStream\(this\.video\)\]\)/,
    'one native stream supplies paired capture');
  assert.match(src, /const track = stream\.getAudioTracks\(\)\[0\];[\s\S]{0,600}streamId: this\.streamId/,
    'audio producer carries the explicit stream id');
  assert.match(src, /await this\.publishCamera\(stream\.getVideoTracks\(\)\[0\]\);/,
    'the initial camera comes from the same app-owned capture stream');
  assert.match(src, /private async publishCamera\(track: MediaStreamTrack \| undefined\)[\s\S]{0,700}streamId: this\.streamId/,
    'camera producer carries that exact same stream id');
  assert.match(src, /const streamId = typeof cmd\.streamId === 'string'[\s\S]{0,300}new NativeMediaSession\(callId,[\s\S]{0,300}streamId/,
    'the page-provided call-scoped id is validated before native construction');
});

test('native camera lifecycle keeps microphone continuity and retires old remote video consumers before replacement', () => {
  const src = source();
  assert.match(src, /if \(warmed && hasAudio\) return warmed;/,
    'a camera acquisition failure retains the native microphone stream');
  assert.match(src, /camera-unavailable/,
    'camera-only failure reports a non-terminal video failure');
  assert.match(src, /for \(const \[id, prior\] of this\.consumers\)[\s\S]{0,220}prior\.close\(\)[\s\S]{0,180}this\.remoteVideo = new MediaStream\(\[c\.track\]\)/,
    'replacement remote video closes prior consumer before rendering the new track');
  assert.match(src, /c\.track\.addEventListener\('ended',[\s\S]{0,400}this\.remoteVideo = null/,
    'an ended remote track clears the native renderer without a WebView bridge command');
});

test('native renderer accepts a hidden-only layout and ignores a transient missing PiP rectangle', () => {
  const app = readFileSync('App.tsx', 'utf8');
  assert.match(app, /if \(v\.hidden\) return \{ callId: v\.callId, hidden: true, big: null, pip: null \};/);
  assert.doesNotMatch(app, /v\.pip !== null && !pip/);
  assert.match(app, /const nativeBigLayout = nativeVideoLayout\?\.hidden \? null : nativeVideoLayout\?\.big \?\? null;/);
});

test('the retained native LiveKit fallback is audio-only', () => {
  const src = source();
  const start = src.indexOf('class NativeLiveKitSession');
  const end = src.indexOf('const CALL_ID =', start);
  assert.ok(start >= 0 && end > start, 'native LiveKit session block exists');
  const block = src.slice(start, end);
  assert.match(block, /takeStream\(false\)/, 'fallback acquires only app-owned microphone audio');
  assert.doesNotMatch(block, /Track\.Source\.Camera|setCamera\(|remoteVideo|localVideo|publishedVideo|nativeVideo/);
  assert.doesNotMatch(src, /consumerClosed|dropConsumer/);
});
