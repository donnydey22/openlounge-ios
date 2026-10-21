// Native iOS parity with web — no Opus DTX, faster ICE-restart cadence, and platform-default capture processing.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const src = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
test('native producer: Opus DTX off, FEC on', () => {
  const s = src('src/nativeMedia.ts');
  assert.match(s, /opusDtx: false/);
  assert.match(s, /opusFec: true/);
});
test('ICE restart cadence back to UDP starts at 0/500 ms', () => {
  assert.match(src('src/nativeMedia.ts'), /const delays = \[0, 500, 1000, 2000, 4000\]/);
});
test('native capture leaves AEC, NS, AGC, and AVAudioSession input gain at platform defaults', () => {
  const media = src('src/nativeMedia.ts');
  const manager = src('modules/openlounge-calls/ios/OLCallManager.swift');
  assert.match(media, /getUserMedia\(\{ audio: true, video:/);
  assert.doesNotMatch(media, /echoCancellation|noiseSuppression|autoGainControl/);
  assert.doesNotMatch(manager, /setInputGain|isInputGainSettable|inputGain/);
});
