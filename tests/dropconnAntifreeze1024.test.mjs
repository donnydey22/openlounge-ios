// FX-078 / FX-079 must-pass (b69). Replays calls bbbe198f (peer drop, "Unknown media session") and 30dc469c (8 fps rung).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const src = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
const helpers = src.slice(src.indexOf('export const FREEZE'), src.indexOf('export const isSessionGone'));
const isGoneSrc = src.match(/export const isSessionGone = ([^\n]+);/)[1];
// eslint-disable-next-line no-new-func
const load = () => new Function(`${helpers.replace(/export /g, '').replace(/ as const/g, '').replace(/: FreezeAction \| null/g, '').replace(/type FreezeAction[^\n]+\n/, '').replace(/private |<FreezeAction>|: number|: unknown/g, '')}; return { FREEZE, FrozenFrameWatchdog, isSessionGone: ${isGoneSrc.replace(/: unknown/g, '')} };`)();

test('bbbe198f: SFU "Unknown media session" reply is recognised as session gone → failed{gone} (page rejoins)', () => {
  const { isSessionGone } = load();
  assert.equal(isSessionGone('Unknown media session'), true);
  assert.equal(isSessionGone('UDP media unavailable'), false);
  assert.match(src, /this\.emit\(\{ state: 'failed', gone: true \}\)/);
  assert.match(src, /this\.diag\('session-gone'/);
});

test('ICE restarts are serialized per direction (coalesced, not overlapping)', () => {
  assert.match(src, /const running = this\.iceRestartInFlight\.get\(direction\);\s*if \(running\) \{ this\.diag\('ice-restart-coalesced'/);
  assert.match(src, /if \(this\.sessionGone\) return; \/\/ FX-078/);
});

test('frozen-frame watchdog: keyframe ~1.5 s, resume ~4 s, resync ~8 s, wired after the first frame', () => {
  const { FrozenFrameWatchdog } = load();
  const d = new FrozenFrameWatchdog(); let f = 0; const acts = [];
  for (let t = 0; t <= 12_000; t += 500) { if (t <= 2_000) f++; const a = d.push(t, f); if (a) acts.push(`${t - 2_000}:${a}`); }
  assert.deepEqual(acts, ['1500:keyframe', '4000:resume', '8000:resync']);
  assert.match(src, /void this\.watchFrozen\(c\)/);
  assert.match(src, /'ms:consumer:requestKeyFrame'/);
});

test('30dc469c: fps floor 15 on the ladder, sender prefers frame rate over resolution', () => {
  assert.match(src, /videoFps: Math\.max\(FREEZE\.minFps,/);
  assert.match(src, /degradationPreference = FREEZE\.degradationPreference/);
  assert.equal(load().FREEZE.minFps, 15);
});
