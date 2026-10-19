// iPhone video calls never grab the mic natively / never enable manual native audio (b47/b48 placed-video silence)
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const app = readFileSync(new URL('../App.tsx', import.meta.url), 'utf8');
const nm = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
const na = readFileSync(new URL('../modules/openlounge-calls/ios/OLNativeAudio.swift', import.meta.url), 'utf8');
const cm = readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift', import.meta.url), 'utf8');
assert.match(app, /op: 'prewarm', video: a\.video === true/, 'answer prewarm carries the call kind');
assert.match(app, /call:outgoing' && v\.video === true\) void nativeMedia\.current\?\.handle\(\{ op: 'prewarm', video: true \}\)/, 'placed video drops any prewarm');
assert.match(nm, /case 'prewarm':\s*\/\/[^\n]*\n\s*if \(cmd\.video === true\) \{\s*dropPrewarm\(\);\s*return false;/, 'video prewarm never captures');
assert.match(na, /if video \{\s*if rtc\.isAudioEnabled \{ rtc\.isAudioEnabled = false \}\s*if rtc\.useManualAudio \{ rtc\.useManualAudio = false \}/, 'video: manual audio off');
assert.match(na, /if video \{ setCallKind\(video: true\); return \}/, 'video: native engine never enabled on activate');
assert.match(cm, /didActivate\(audioSession, video: callVideo\)/);
assert.equal((cm.match(/OLNativeAudio\.setCallKind\(video:/g) || []).length, 3, 'outgoing page msg, start, answer');
assert.match(cm, /\.videoChat : \.voiceChat/, 'video session mode = videoChat');
console.log('videoNoMicGrab ok');
