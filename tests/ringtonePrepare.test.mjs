// Linphone cut: CallKit owns ringtone — call:ringtonePrepare is a no-op; prepareRingtoneSession deleted.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const mgr = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
const owner = readFileSync('modules/openlounge-calls/ios/OLAudioSessionOwner.swift', 'utf8');
const engine = readFileSync('modules/openlounge-call-engine/ios/PJSIPEngine.swift', 'utf8');
test('ringtonePrepare is no-op (CallKit owns ringtone)', () => {
  assert.match(mgr, /case "call:ringtonePrepare":[\s\S]{0,120}break/);
  assert.doesNotMatch(mgr, /func prepareRingtoneSession\(/);
  assert.doesNotMatch(mgr, /func prepareHeadsetSession\(/);
});
test('OLAudioSessionOwner is sole call configure path', () => {
  assert.match(owner, /configureForCall/);
  assert.match(owner, /playAndRecord/);
  assert.match(owner, /voiceChat/);
  assert.match(owner, /allowBluetooth/);
  assert.doesNotMatch(owner, /CategoryOptions = \[[^\]]*mixWithOthers/);
  assert.doesNotMatch(owner, /CategoryOptions = \[[^\]]*allowBluetoothA2DP/);
  assert.match(owner, /mode: \.voiceChat/); assert.doesNotMatch(owner, /mode: \.videoChat/);
  assert.match(mgr, /beginCallAudioSession\(/);
  assert.match(mgr, /OLAudioSessionOwner\.shared\.configureForCall/);
});
test('PJSIPEngine opens sound only after didActivate; no empty-route early return', () => {
  assert.match(engine, /func resetForNewCall/);
  assert.match(engine, /sessionActive = true/);
  assert.doesNotMatch(engine, /outputs\.isEmpty/);
  assert.match(engine, /ensureSound/);
});
test('didDeactivate does not teardown', () => {
  assert.match(mgr, /didDeactivate[\s\S]{0,400}NO teardown here/);
  assert.match(mgr, /audioSessionDidDeactivate\(\)/);
});
