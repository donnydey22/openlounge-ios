// Behaviour test for the 60 s block reconnect hang: concurrent connects for one call coalesce into a single build,
// and closing a session aborts its pending connect immediately (no 12 s wait on a dead transport).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import ts from 'typescript';

const dir = mkdtempSync(join(tmpdir(), 'nm-'));
let js = ts.transpileModule(readFileSync('src/nativeMedia.ts', 'utf8'), { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
js = js.replace(/import \{[^}]*\} from '@livekit\/react-native-webrtc';/, 'const mediaDevices = globalThis.__md;')
  .replace(/import \{[^}]*\} from '@livekit\/react-native';/, 'const registerGlobals = () => {};')
  .replace(/import\('mediasoup-client'\)/g, 'Promise.resolve(globalThis.__ms)');
writeFileSync(join(dir, 'nm.mjs'), js);

const track = () => ({ readyState: 'live', enabled: true, stop() { this.readyState = 'ended'; } });
globalThis.__md = { getUserMedia: async () => { const t = track(); return { getAudioTracks: () => [t], getTracks: () => [t] }; } };
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

test('paired native video producers carry one explicit stream ID and replacement video consumers are closed', () => {
  const src = readFileSync('src/nativeMedia.ts', 'utf8');
  assert.match(src, /streamId: this\.streamId[\s\S]{0,2400}streamId: this\.streamId/);
  assert.match(src, /for \(const \[id, prior\] of this\.consumers\)[\s\S]{0,180}prior\.close\(\)/);
});
