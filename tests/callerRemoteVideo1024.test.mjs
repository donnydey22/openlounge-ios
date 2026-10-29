// FX-062 (Oct 24): iPhone native caller saw a black remote tile. A slow cellular consume/resume blew the 12 s connect
// budget, close() ended the shared capture (mediasoup-client stopTracks default), and every rebuild failed 'track ended'.
import test from 'node:test'; import assert from 'node:assert/strict'; import fs from 'node:fs';
const s = fs.readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
const inner = s.slice(s.indexOf('private async connectInner'), s.indexOf('private emitVideoState'));
test('caller remote video: producers never stop the controller-owned capture', () => {
  assert.match(s, /stopTracks: false,\n\s*appData: \{ source: 'mic'/);
  assert.match(s, /appData: \{ source: 'camera', native: true \},\n\s*stopTracks: false/);
});
test('caller remote video: consumer sync is outside the connect budget and retried', () => {
  assert.match(inner, /void this\.syncConsumersRetrying\(\);\n\s*await waitConnected\(this\.send\)/);
  assert.doesNotMatch(inner, /await this\.syncConsumers\(\)/);
  assert.match(s, /await this\.resumeConsumer\(c\.id\)/);
  assert.match(s, /private async resumeConsumer[\s\S]{0,300}i >= 3/);
});
test('caller remote video: a rebuild never reuses an ended capture track', () => {
  assert.match(s, /this\.capture\?\.callId === callId && this\.capture\.stream\.getTracks\(\)\.some\(\(t\) => t\.readyState === 'ended'\)/);
});
