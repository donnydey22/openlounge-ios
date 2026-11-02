// b75: Swift lane routing + SDP translation static checks
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const src = readFileSync(new URL('../src/swiftLane.ts', import.meta.url), 'utf8');
const swift = readFileSync(new URL('../modules/openlounge-calls/ios/OLNativeAudioLane.swift', import.meta.url), 'utf8');
const mgr = readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift', import.meta.url), 'utf8');
const nm = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
const pod = readFileSync(new URL('../modules/openlounge-calls/ios/OpenLoungeCalls.podspec', import.meta.url), 'utf8');

// mirror of routeSwiftLane (kept literal-checked below)
const route = (x) => x.os === 'ios' && !x.video && x.incoming && x.peerPlatform === 'android';
test('routing literal matches', () => assert.match(src, /return x\.os === 'ios' && !x\.video && x\.incoming && x\.peerPlatform === 'android';/));
test('android → iPhone incoming audio routes to Swift lane', () => assert.equal(route({ os: 'ios', video: false, incoming: true, peerPlatform: 'android' }), true));
for (const [name, x] of [
  ['iOS → iOS', { os: 'ios', video: false, incoming: true, peerPlatform: 'ios' }],
  ['unknown caller platform', { os: 'ios', video: false, incoming: true, peerPlatform: null }],
  ['outgoing', { os: 'ios', video: false, incoming: false, peerPlatform: 'android' }],
  ['video', { os: 'ios', video: true, incoming: true, peerPlatform: 'android' }],
  ['Android device', { os: 'android', video: false, incoming: true, peerPlatform: 'ios' }],
]) test(`${name} stays on existing path`, () => assert.equal(route(x), false));
test('only incoming payloads feed the routing map', () => assert.match(src, /v\?\.type !== 'call:incoming'/));
test('non-connect ops only divert when the lane is active', () => assert.match(nm, /cmd\.op === 'connect' \|\| cmd\.op === 'prepare' \|\| this\.swiftActive\(\)/));
test('no libmediasoupclient / second WebRTC', () => {
  assert.doesNotMatch(pod, /mediasoup|libwebrtc|Mediasoup\.xcframework/i);
  assert.match(pod, /'StreamWebRTC', '~> 125\.6422\.070'/);
  assert.doesNotMatch(swift, /import Mediasoup|Mediasoup\w*Client/);
});
test('b80: audio starts ONLY in CallKit didActivate for Android callers; no connect-path safety net', () => {
  assert.doesNotMatch(swift, /await Self\.waitForActivation/);
  assert.doesNotMatch(swift + mgr, /laneEnsureAudio/);
  assert.match(swift, /useManualAudio = true\s*\n\s*if !Self\.activated \{ rtc\.isAudioEnabled = false \}/);
  assert.match(mgr, /didActivate audioSession[\s\S]*isAndroidCall[\s\S]*laneActivate\(audioSession\)[\s\S]*callKitActivated\(\)[\s\S]*resumeAudioTracks\(\)[\s\S]*\} else \{/);
  assert.match(mgr, /callerPlatform[\s\S]*markAndroidCall/);
  assert.match(swift, /if let l = shared, !l\.closed/);
  assert.doesNotMatch(swift, /setCategory|setActive\(|AVAudioSession\.sharedInstance\(\)\.set/);
  assert.match(nm, /case 'prepare': return CALL_ID\.test\(callId\) && shouldUseSwiftLane\(cmd\) \? true : undefined;/);
});
test('Opus 48k, DTLS client role, ICE-lite SDP', () => {
  assert.match(swift, /opus\/48000\/2/);
  assert.match(swift, /"role": "client"/);
  assert.match(swift, /a=ice-lite/);
  assert.match(swift, /setup: "passive"/);
  assert.match(swift, /setup: "actpass"/);
});
