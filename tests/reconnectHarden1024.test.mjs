// FX-063 must-pass: call c0f559f2 (cellular dips). restartIce stalled 8 s on a dead page socket and nothing re-consumed
// or re-resumed after recovery. Extend-only hardening of the existing persistent restart loop.
import test from 'node:test'; import assert from 'node:assert/strict'; import fs from 'node:fs';
const s = fs.readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
test('restartIce has its own short timeout (< page relay 8 s) so the backoff loop keeps going', () => {
  const ms = Number(s.match(/RESTART_ICE_TIMEOUT_MS = ([\d_]+)/)[1].replace(/_/g, ''));
  assert.ok(ms > 0 && ms < 8000);
  assert.match(s, /private async restartIce[\s\S]{0,600}Promise\.race\([\s\S]{0,300}RESTART_ICE_TIMEOUT_MS/);
});
test('ICE recovery re-consumes and re-resumes every consumer (no paused audio after a dip)', () => {
  assert.match(s, /const recovered = this\.iceRestarted\.delete\(direction\);[\s\S]{0,400}if \(recovered && this\.connected\) void this\.afterRecovery\(\)/);
  assert.match(s, /private async afterRecovery\(\) \{\n\s*await this\.syncConsumers\(\)[\s\S]{0,200}await this\.resumeConsumer\(c\.id\)/);
});
test('tracks stay alive across restarts and the restart loop is unchanged (extend, not redesign)', () => {
  assert.equal((s.match(/stopTracks: false/g) || []).length >= 2, true);
  assert.match(s, /const delays = \[0, 500, 1000, 2000, 4000\]/);
  assert.doesNotMatch(s.slice(s.indexOf('private async afterRecovery'), s.indexOf('async restartIceAll')), /\.stop\(\)|close\(\)/);
});
