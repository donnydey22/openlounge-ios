// FX-080 (iOS lane) must-pass: native camera simulcast is opt-in (connect simulcast:true), 3 ascending layers,
// low layer always on at >= 15 fps under every ladder budget; flag off = the proven single VP8 encoding.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const sim = readFileSync(new URL('../src/simulcast.ts', import.meta.url), 'utf8');
const js = sim.replace(/export /g, '').replace(/ as const/g, '').replace(/type Enc = [^\n]+\n/, '').replace(/: (boolean|number|Enc\[\]|\{ videoBps\?: number; videoFps\?: number \})/g, '');
// eslint-disable-next-line no-new-func
const { nativeCameraEncodings, nativeSimulcastLadder } = new Function(`${js}; return { nativeCameraEncodings, nativeSimulcastLadder };`)();
const src = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');

test('flag off: exactly the proven single encoding (850 kbps, 30 fps, scale 1)', () => {
  assert.deepEqual(nativeCameraEncodings(false, 850_000), [{ maxBitrate: 850_000, maxFramerate: 30, scaleResolutionDownBy: 1, priority: 'high', networkPriority: 'high' }]);
});
test('flag on: 3 ascending layers, top capped at the native max, low layer high priority', () => {
  const e = nativeCameraEncodings(true, 850_000);
  assert.deepEqual(e.map((x) => x.scaleResolutionDownBy), [4, 2, 1]);
  assert.deepEqual(e.map((x) => x.maxBitrate), [150_000, 400_000, 850_000]);
  assert.equal(e[0].priority, 'high');
});
test('ladder on layers: low always active >= 15 fps; upper layers only within budget', () => {
  for (const b of [60_000, 150_000, 400_000, 600_000, 1_200_000, 2_000_000]) {
    const e = nativeSimulcastLadder(nativeCameraEncodings(true, 850_000), { videoBps: b, videoFps: 8 });
    assert.equal(e[0].active, true);
    for (const x of e) assert.ok(x.maxFramerate >= 15);
    const used = e.filter((x) => x.active).reduce((a, x) => a + x.maxBitrate, 0);
    assert.ok(used <= Math.max(b, 150_000), `${b}: ${used}`);
  }
});
test('wiring: connect cmd sets the flag; publishCamera + ladder use the layered helpers', () => {
  assert.match(src, /s\.simulcast = cmd\.simulcast === true; \/\/ FX-080/);
  assert.match(src, /\.\.\.\(this\.simulcast \? \{ encodings: nativeCameraEncodings\(true, NATIVE_CAMERA_MAX_BPS\)/);
  assert.match(src, /const plan = layers\.length > 1 \? nativeSimulcastLadder/);
});
