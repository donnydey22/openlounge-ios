// Stale CallKit clearing (Oct 17): orphaned / expired calls are ended before a new incoming call is reported.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const mgr = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
test('clearStaleCalls runs before busy check on VoIP push', () => {
  assert.match(mgr, /let persistedUUID = ok \? canonicalUUID\(for: callId\) : nil[\s\S]{0,160}clearStaleCalls\(preserving: persistedUUID\)[\s\S]{0,1400}let stale = [\s\S]{0,900}let busy = !stale && hasLiveCall/);
});
test('page call:incoming delegates into the canonical PushKit report path', () => {
  assert.match(mgr, /case "call:incoming":[\s\S]{0,700}handleIncoming\(incoming, completion: \{\}\)/);
  assert.match(mgr, /private func handleIncoming[\s\S]{0,2400}clearStaleCalls\(preserving: persistedUUID\)/);
});
test('orphans ended with CXEndCallAction, fallback reportCall; expired unanswered reported ended', () => {
  assert.match(mgr, /callObserver\.calls where !obs\.hasEnded && obs\.uuid != preservedUUID && calls\[obs\.uuid\] == nil/);
  assert.match(mgr, /CXTransaction\(action: CXEndCallAction\(call: uuid\)\)[\s\S]{0,200}reportCall\(with: uuid, endedAt: nil, reason: \.remoteEnded\)/);
  assert.match(mgr, /where c\.incoming && !c\.answered && !c\.ended[\s\S]{0,300}reportCall\(with: c\.uuid, endedAt: nil, reason: \.unanswered\)/);
});
