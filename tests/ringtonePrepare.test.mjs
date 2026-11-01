// iOS 75: the page may notify native code that a ring is imminent, but CallKit owns the
// ringtone and AVAudioSession for incoming calls.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const bridge = readFileSync('src/bridge.ts', 'utf8');
const mgr = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
const na = readFileSync('modules/openlounge-calls/ios/OLNativeAudio.swift', 'utf8');
test('bridge passes call:ringtonePrepare through', () => assert.match(bridge, /case 'call:ringtonePrepare':\s*\n.*\n\s*return wrap\(\{ type: 'call:ringtonePrepare' \}\)/));
test('manager resets stale state but defers incoming ringtone/session ownership to CallKit', () => {
  assert.match(mgr, /case "call:ringtonePrepare":[\s\S]{0,240}resetAudioState\("ringtone-prepare"\)[\s\S]{0,180}deferred to CallKit/);
  assert.doesNotMatch(mgr, /prepareRingtoneSession\(/);
});
test('engine fully stopped when idle after a call', () => {
  assert.match(na, /static func stopIdle\(\)[\s\S]{0,200}isAudioEnabled = false/);
  assert.match(mgr, /setCategory\(saved\.0, mode: saved\.1, options: saved\.2\)\s*OLNativeAudio\.stopIdle\(\)/);
});
