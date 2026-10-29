// Ringtone fix (b39 "thin and quiet"): the page's call:ringtonePrepare reaches CallKit's manager, which stops the
// idle native audio engine and re-applies the ring/speaker session before the tone.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const bridge = readFileSync('src/bridge.ts', 'utf8');
const mgr = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
const na = readFileSync('modules/openlounge-calls/ios/OLNativeAudio.swift', 'utf8');
test('bridge passes call:ringtonePrepare through', () => assert.match(bridge, /case 'call:ringtonePrepare':\s*\n.*\n\s*return wrap\(\{ type: 'call:ringtonePrepare' \}\)/));
test('manager prepares ring session: engine stopped, playAndRecord/.default/.defaultToSpeaker, speaker override, never mid-call', () => {
  assert.match(mgr, /case "call:ringtonePrepare":[\s\S]{0,200}prepareRingtoneSession\(\)/);
  assert.match(mgr, /func prepareRingtoneSession\(\) \{\s*guard !hasLiveCall else \{ return \}\s*OLNativeAudio\.stopIdle\(\)\s*prepareHeadsetSession\(\)[\s\S]{0,200}overrideOutputAudioPort\(Self\.headsetAttached\(\) \? \.none : \.speaker\)/);
  assert.match(mgr, /setCategory\(\.playAndRecord, mode: \.default, options: opts\)/);
});
test('engine fully stopped when idle after a call', () => {
  assert.match(na, /static func stopIdle\(\)[\s\S]{0,200}isAudioEnabled = false/);
  assert.match(mgr, /setCategory\(saved\.0, mode: saved\.1, options: saved\.2\)\s*OLNativeAudio\.stopIdle\(\)/);
});
