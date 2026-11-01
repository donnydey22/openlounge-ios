import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const core = readFileSync('modules/openlounge-calls/ios/OLTelecomCore.swift', 'utf8');
const manager = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
const calls = readFileSync('src/calls.ts', 'utf8');
const app = readFileSync('App.tsx', 'utf8');

test('the local telecom core is the only source constructor for PushKit and CallKit', () => {
  assert.match(core, /final class OLTelecomRegistration/);
  assert.equal((core.match(/CXProvider\(configuration:/g) || []).length, 1);
  assert.equal((core.match(/PKPushRegistry\(queue:/g) || []).length, 1);
  assert.doesNotMatch(manager, /CXProvider\(configuration:/);
  assert.doesNotMatch(manager, /PKPushRegistry\(queue:/);
  assert.match(manager, /OLTelecomRegistration\.shared\.start\(providerDelegate: self, pushDelegate: self\)/);
  assert.match(core, /configuration\.ringtoneSound = "openlounge-incoming\.caf"/);
});

test('a canonical CallSession owns reporting state, completion callbacks, and a two-second watchdog', () => {
  assert.match(core, /final class OLCallSession/);
  assert.match(core, /var reporting = false/);
  assert.match(core, /var reported = false/);
  assert.match(core, /var reportCompletions: \[\(\) -> Void\] = \[\]/);
  assert.match(manager, /DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 2, execute: work\)/);
  assert.match(manager, /type": "incomingFallback"/);
  assert.match(app, /a\.type === 'incomingFallback'/);
  assert.match(app, /forwardPageCallMessage\(\{ type: 'call:answering', callId: id, video: incomingCard\.video \}\)/);
});

test('duplicate ingress completes but never makes a second CallKit incoming report', () => {
  const start = manager.indexOf('if ok, let existing = call(callId)');
  const end = manager.indexOf('// Every VoIP push must produce a reported call', start);
  const duplicate = manager.slice(start, end);
  assert.match(duplicate, /incoming-duplicate/);
  assert.match(duplicate, /completion\(\)/);
  assert.doesNotMatch(duplicate, /reportNewIncomingCall/);
  assert.match(manager, /reportIncoming\(c, update: update, stale: stale, busy: busy\)/);
  assert.match(manager, /let backoff: \[TimeInterval\] = \[0\.20, 0\.60\]/);
});

test('incoming answer has no page-driven session activation and didActivate is the native boundary', () => {
  const answer = manager.slice(manager.indexOf('perform action: CXAnswerCallAction'), manager.indexOf('perform action: CXEndCallAction'));
  assert.match(answer, /if !c\.incoming \{ configureAudio\(\) \}/);
  assert.doesNotMatch(answer, /setActive\(/);
  assert.doesNotMatch(manager, /activateInAppAnswer/);
  assert.doesNotMatch(manager, /prepareRingtoneSession/);
  assert.match(manager, /provider\(_ provider: CXProvider, didActivate audioSession: AVAudioSession\)/);
});

test('the retained PushKit token is replayed after listener setup', () => {
  assert.match(calls, /const retainedToken = n\.getVoipToken\(\);[\s\S]{0,100}onToken\(retainedToken\)/);
  assert.match(calls, /type: 'callFailure'/);
});

test('a short-lived canonical UUID survives relaunch without persisting credentials and is removed on terminal cleanup', () => {
  assert.match(manager, /private struct PersistedIncomingIdentity: Codable/);
  assert.match(manager, /Credentials and decline tokens[\s\S]{0,180}never stored here/);
  assert.match(manager, /private func canonicalUUID\(for callId: String/);
  assert.match(manager, /clearStaleCalls\(preserving: persistedUUID\)/);
  assert.match(manager, /incoming-recovered[\s\S]{0,180}no second CallKit report/);
  assert.match(manager, /private func removeCanonicalIdentity\(_ c: OLCall\)/);
  assert.match(manager, /private func endAllCalls[\s\S]{0,700}removeCanonicalIdentity\(c\)/);
  assert.match(manager, /perform action: CXEndCallAction[\s\S]{0,300}removeCanonicalIdentity\(c\)/);
});
