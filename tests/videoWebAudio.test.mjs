import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const s = readFileSync(new URL('../modules/openlounge-calls/ios/OLCallManager.swift', import.meta.url), 'utf8');
const act = s.slice(s.indexOf('didActivate audioSession: AVAudioSession'), s.indexOf('didDeactivate audioSession: AVAudioSession'));
assert.match(act, /let nativeVideo = calls\.values\.contains[\s\S]{0,180}if !callVideo \|\| nativeVideo \{[\s\S]{0,80}didActivate\(audioSession, video: nativeVideo\)/, 'voice and explicitly granted native video activate; ungranted video does not');
assert.equal((act.match(/OLNativeAudio\.didActivate/g) || []).length, 1, 'no unconditional native activation');
const n = readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
assert.ok(!/prewarmNativeMedia\(\)/.test(readFileSync(new URL('../src/calls.ts', import.meta.url), 'utf8')), 'no native prewarm from dial path');
assert.match(n, /case 'prewarm'/);
console.log('videoWebAudio: ok');

assert.match(readFileSync(new URL('../modules/openlounge-calls/ios/OLNativeAudio.swift', import.meta.url), 'utf8'), /setUp\(video: Bool = false\)[\s\S]{0,700}videoChat/);
