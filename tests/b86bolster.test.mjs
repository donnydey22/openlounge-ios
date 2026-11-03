import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const m = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
test('b86: stale didDeactivate for a not-yet-activated new lane call is ignored first', () => {
  assert.match(m, /didDeactivate audioSession: AVAudioSession\) \{\n    if staleLaneDeactivate\(\) \{ return \}/);
});
test('b86: activation watchdog only requests CallKit hold/unhold (max 2), never starts audio', () => {
  const b = m.slice(m.indexOf('private func armActivationWatchdog'), m.indexOf('private var ckDiagBuf'));
  assert.match(b, /guard attempt <= 2/);
  assert.match(b, /CXSetHeldCallAction/);
  assert.doesNotMatch(b, /isAudioEnabled|setActive|laneActivate\(|OLNativeAudio\.didActivate|resumeAudioTracks/);
});
test('b86: didActivate lane audio-start sequence unchanged (b82)', () => {
  assert.match(m, /OLNativeAudio\.laneActivate\(audioSession\)\n      OLNativeAudioLane\.callKitActivated\(\)\n      OLNativeAudioLane\.live\?\.resumeAudioTracks\(\)/);
});
