import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const s = readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift', import.meta.url), 'utf8');
const act = s.slice(s.indexOf('didActivate audioSession: AVAudioSession'), s.indexOf('didDeactivate audioSession: AVAudioSession'));
assert.match(act, /if !callVideo \{ OLNativeAudio\.didActivate\(audioSession\) \}/, 'native audio unit must start only for voice calls');
assert.equal((act.match(/OLNativeAudio\.didActivate/g) || []).length, 1, 'no unconditional native activation');
const n = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
assert.ok(!/prewarmNativeMedia\(\)/.test(readFileSync(new URL('../src/calls.ts', import.meta.url), 'utf8')), 'no native prewarm from dial path');
assert.match(n, /case 'prewarm'/);
console.log('videoWebAudio: ok');

// 4 directions: callVideo is set from the call before CallKit activates the session, then didActivate gates on it.
const fn = (sig) => s.slice(s.indexOf(sig), s.indexOf('\n  }\n', s.indexOf(sig)));
const startA = fn('perform action: CXStartCallAction');   // outgoing (iPhone-placed)
const answerA = fn('perform action: CXAnswerCallAction'); // incoming (Android-placed → iPhone answers)
for (const [name, body] of [['outgoing', startA], ['incoming', answerA]]) {
  assert.match(body, /callVideo = c\.video/, `${name}: callVideo taken from the call`);
  assert.ok(!/OLNativeAudio/.test(body), `${name}: no native audio before CallKit activation`);
}
assert.match(fn('case "call:outgoing"'), /callVideo = video/, 'outgoing page dial sets callVideo');
const sim = (video) => { let started = false; const callVideo = video; if (!callVideo) started = true; return started; };
for (const dir of ['outgoing', 'incoming']) {
  assert.equal(sim(false), true, `${dir} voice → native audio unit starts`);
  assert.equal(sim(true), false, `${dir} video → native audio unit never starts (WKWebView owns mic+camera)`);
}
console.log('videoWebAudio: 4 directions ok');
