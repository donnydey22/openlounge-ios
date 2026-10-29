import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const nativeAudio = readFileSync('modules/openlounge-calls/ios/OLNativeAudio.swift', 'utf8');
const manager = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');

const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing ${start}`);
  const to = source.indexOf(end, from);
  assert.notEqual(to, -1, `missing ${end}`);
  return source.slice(from, to);
};

test('native WebRTC inherits the CallKit route options that select speaker, receiver, or headset', () => {
  const setup = between(nativeAudio, 'static func setUp(', 'static func didActivate(');
  assert.match(setup, /session: AVAudioSession = AVAudioSession\.sharedInstance\(\)/);
  assert.match(setup, /let callCategory: AVAudioSession\.Category = session\.category == \.playAndRecord/);
  assert.match(setup, /let callMode: AVAudioSession\.Mode = \(session\.mode == \.voiceChat \|\| session\.mode == \.videoChat\)/);
  assert.match(setup, /cfg\.categoryOptions = session\.categoryOptions/);
  assert.doesNotMatch(setup, /cfg\.categoryOptions = \[\.allowBluetooth, \.allowBluetoothA2DP\]/,
    'WebRTC must not replace CallKit defaultToSpeaker with its receiver-oriented defaults');

  const callConfig = between(manager, 'private func configureAudio()', 'private func applySpeakerOverride()');
  assert.match(callConfig, /if speaker && !headset \{ opts\.insert\(\.defaultToSpeaker\) \}/);
  assert.match(callConfig, /if wantSpeaker != onSpeaker \{[\s\S]{0,180}overrideOutputAudioPort/);
});

test('CallKit activation passes the activated session into native WebRTC without adding playback gain', () => {
  const activated = between(nativeAudio, 'static func didActivate(', '/// idle after a call');
  assert.match(activated, /setUp\(video: video, session: session\)/);
  assert.match(activated, /audioSessionDidActivate\(session\)/);
  assert.match(activated, /rtc\.isAudioEnabled = true/);
  assert.doesNotMatch(nativeAudio, /setInputGain|inputGain|AVAudioMixerNode/,
    'the receive-side fix is routing parity, not an unsafe gain boost that could clip or echo');
});
