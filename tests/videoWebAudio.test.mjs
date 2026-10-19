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

assert.match(nativeAudio, /cfg\.mode = \(video \? AVAudioSession\.Mode\.videoChat : AVAudioSession\.Mode\.voiceChat\)\.rawValue/,
  'granted native video uses videoChat; voice stays voiceChat');
assert.match(nativeAudio, /static func didActivate\(_ session: AVAudioSession, video: Bool = false\)[\s\S]{0,260}setUp\(video: video\)/,
  'the active CallKit mode is passed into the WebRTC audio unit');

assert.ok(!/prewarmNativeMedia\(\)/.test(calls), 'the generic native call action does not prewarm media outside the call engine');
assert.match(media, /case 'prewarm'/, 'the app accepts explicit call-engine prewarm commands only');
assert.match(media, /takeStream\(this\.video\)/, 'native capture receives the explicit video flag');
assert.match(media, /if \(this\.video\) \{[\s\S]{0,380}camera-unavailable/,
  'camera failure keeps the native audio call alive');

console.log('videoWebAudio: CallKit voice/native-video gates and camera-only fallback verified');
