// Persistent reconnecting (Donny, Oct 15 2026): the app keeps restarting ICE with backoff while the call lives, and a
// page-driven rebuild after a total outage gets fresh transports instead of re-attaching to the dead session.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const src = readFileSync('src/nativeMedia.ts', 'utf8');

test('connect {rebuild:true} skips the reload re-attach and builds fresh transports', () => {
  assert.match(src, /const rebuild = cmd\.rebuild === true;/);
  assert.match(src, /if \(!rebuild && cur\?\.alive && cur\.callId === callId && cur\.tcpOnly === tcpOnly\)/);
});
test('ICE keeps restarting with backoff while the call lives (no give-up)', () => {
  assert.match(src, /private async keepRestarting\([\s\S]{0,200}for \(let i = 0; !this\.closed && this\.iceRestarted\.has\(direction\); i\+\+\)/);
});
test('restartIce op restarts both transports in place', () => {
  assert.match(src, /case 'restartIce':\s*\n\s*await this\.session\?\.restartIceAll\(\);/);
});
