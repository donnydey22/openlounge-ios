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
