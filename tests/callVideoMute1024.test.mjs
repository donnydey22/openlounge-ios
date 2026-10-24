// Donny t3300u (Oct 24 2026 4:11 AM MST, b62 → Keiko Android 0.3.20-36, call 574e953a): self-view in the remote
// tile + flickering Mute button. Source checks (must-pass, FX-061 / FX-063).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const app = readFileSync('App.tsx', 'utf8');
const nm = readFileSync('src/nativeMedia.ts', 'utf8');
const sw = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');

test('FX-061 remote tile never renders the local stream', () => {
  assert.match(app, /const streamFor = \(kind: 'local' \| 'remote'\) => kind === 'local' \? null : remoteStream;/);
  assert.match(app, /localTrackIds\.has\(t\.id\)/);
  assert.match(app, /nativeVideo\.remote\.toURL\(\) !== nativeVideo\.local\.toURL\(\)/);
});
test('FX-061 own producers are never consumed as remote', () => {
  assert.match(nm, /pid === this\.producer\?\.id \|\| pid === this\.videoProducer\?\.id\)\) continue;/);
});
test('FX-063 CallKit mute echoes matched FIFO, not re-emitted', () => {
  assert.match(sw, /private var pendingPageMutes: \[Bool\] = \[\]/);
  assert.match(sw, /if let i = pendingPageMutes\.firstIndex\(of: action\.isMuted\) \{ pendingPageMutes\.removeSubrange\(0\.\.\.i\); return \}/);
  assert.match(sw, /pendingPageMutes\.append\(muted\)/);
});

test('FX-063 hang-up from CallKit (lock screen / Dynamic Island) clears mute state so the next call starts clean', () => {
  const s = readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift', import.meta.url), 'utf8');
  const end = s.slice(s.indexOf('perform action: CXEndCallAction'), s.indexOf('perform action: CXSetMutedCallAction'));
  assert.match(end, /pageMuted = nil; pendingPageMutes = \[\]/);
  const ended = s.slice(s.indexOf('case "call:ended":'), s.indexOf('case "call:muted":'));
  assert.match(ended, /pendingPageMutes = \[\]/);
  assert.match(ended, /reportCall\(with: c\.uuid, endedAt: Date\(\), reason: \.remoteEnded\)/);
});

test('FX-064 hang-up releases mic and camera even if the page is cold, and on page call:ended', () => {
  const app = readFileSync(new URL('../App.tsx', import.meta.url), 'utf8');
  const nm = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
  assert.match(app, /a\.type === 'decline' \|\| a\.type === 'hangup'\) \{[\s\S]{0,300}nativeMedia\.current\?\.closeAll\(\);/);
  assert.match(app, /v\?\.type === 'call:ended'\) \{\s*nativeMedia\.current\?\.closeAll\(\);\s*setNativeVideoLayout\(null\);/);
  assert.match(nm, /closeAll\(dropPrewarm = true\) \{[\s\S]{0,200}this\.capture\?\.stream\.getTracks\(\)\.forEach\(\(t\) => t\.stop\(\)\)/);
});

test('FX-064 outgoing start is CallKit-native: CXStartCallAction → startedConnecting → connected', () => {
  const s = readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift', import.meta.url), 'utf8');
  assert.match(s, /CXStartCallAction\(call: c\.uuid/);
  assert.match(s, /reportOutgoingCall\(with: action\.callUUID, startedConnectingAt: Date\(\)\)/);
  assert.match(s, /reportOutgoingCall\(with: c\.uuid, connectedAt: Date\(\)\)/);
});
