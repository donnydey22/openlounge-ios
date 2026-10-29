import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const source = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const manager = source('modules/openlounge-calls/ios/OLCallManager.swift');
const nativeAudio = source('modules/openlounge-calls/ios/OLNativeAudio.swift');
const media = source('src/nativeMedia.ts');
const calls = source('src/calls.ts');
const between = (start, end) => {
  const from = manager.indexOf(start);
  assert.notEqual(from, -1, `missing ${start}`);
  const to = manager.indexOf(end, from);
  assert.notEqual(to, -1, `missing ${end}`);
  return manager.slice(from, to);
};

// b52114c coverage, adapted for the intentional paired-native-video exception.
const activated = between('didActivate audioSession: AVAudioSession', 'didDeactivate audioSession: AVAudioSession');
assert.match(activated, /let nativeVideo = calls\.values\.contains[\s\S]{0,220}if !callVideo \|\| nativeVideo \{[\s\S]{0,100}OLNativeAudio\.didActivate\(audioSession, video: nativeVideo\)/,
  'voice and only a server-granted native-video call activate the native audio unit');
assert.equal((activated.match(/OLNativeAudio\.didActivate/g) || []).length, 1, 'no unconditional native activation');

for (const [name, body] of [
  ['outgoing', between('perform action: CXStartCallAction', 'didActivate audioSession: AVAudioSession')],
  ['incoming', between('perform action: CXAnswerCallAction', 'perform action: CXEndCallAction')],
]) {
  assert.match(body, /callVideo = c\.video/, `${name}: CallKit derives video state from its call record`);
  assert.ok(!/OLNativeAudio/.test(body), `${name}: no native WebRTC audio before CallKit activation`);
}
const outgoing = between('case "call:outgoing"', 'case "call:connected"');
assert.match(outgoing, /let nativeMedia = video && \(\(m\["nativeMedia"\] as\? Bool\) \?\? false\)/,
  'video alone never creates the native-media exception');
assert.match(outgoing, /OLCall\(callId: callId, uuid: UUID\(\), incoming: false, video: video, nativeMedia: nativeMedia\)/,
  'the server grant is retained on the outgoing CallKit record');

assert.match(nativeAudio, /let callMode: AVAudioSession\.Mode = \(session\.mode == \.voiceChat \|\| session\.mode == \.videoChat\)/,
  'native WebRTC preserves the activated CallKit voice/video mode');
assert.match(nativeAudio, /cfg\.categoryOptions = session\.categoryOptions/,
  'native WebRTC preserves CallKit speaker, receiver, and headset route options');
assert.match(nativeAudio, /static func didActivate\(_ session: AVAudioSession, video: Bool = false\)[\s\S]{0,300}setUp\(video: video, session: session\)/,
  'the activated CallKit session is passed into the WebRTC audio unit');

assert.ok(!/prewarmNativeMedia\(\)/.test(calls), 'the generic native call action does not prewarm media outside the call engine');
assert.match(media, /case 'prepare':[\s\S]{0,700}ms:join/, 'ring-time preparation loads signaling state without capture');
assert.match(media, /case 'prewarm':[\s\S]{0,120}capture is intentionally deferred/, 'legacy prewarm is a capture-free compatibility no-op');
assert.match(media, /const requestedVideo = cmd\.video === true && cmd\.nativeVideo === true;[\s\S]{0,700}this\.capture = capture \?\? \{ callId, stream, nativeVideo, streamId/,
  'native capture receives and latches the server-granted paired-video state');
assert.match(media, /if \(this\.nativeVideo\) \{[\s\S]{0,380}camera-unavailable/,
  'camera failure keeps the native audio call alive');

console.log('videoWebAudio: CallKit voice/native-video gates and camera-only fallback verified');
