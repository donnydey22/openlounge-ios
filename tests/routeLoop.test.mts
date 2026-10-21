// Model of OLCallManager's AVAudioSession handling (Oct 15 2026 volume pumping). A fake session emits a route change
// for every setCategory (.categoryChange=3) and overrideOutputAudioPort (.override=4), as iOS does. The old handler
// reconfigured on every route change → feedback loop; the 0.3.12 handler only reacts to device changes and is
// idempotent. Source assertions tie the model to the Swift.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SWIFT = readFileSync(new URL("../modules/openlounge-calls/ios/OLCallManager.swift", import.meta.url), "utf8");
const R = { newDevice: 1, oldDeviceGone: 2, categoryChange: 3, override: 4, wake: 6, noRoute: 7, config: 8 } as const;
const DEVICE = new Set<number>([R.newDevice, R.oldDeviceGone, R.wake, R.noRoute]);

function sim(fixed: boolean, initial: number[], cap = 200) {
  const s = { category: "", mode: "", speaker: false };
  let reconfigs = 0, sessionWrites = 0;
  const q: number[] = [...initial];
  const configure = () => {
    reconfigs++;
    const want = { category: "playAndRecord", mode: "voiceChat" };
    if (!fixed || s.category !== want.category || s.mode !== want.mode) { Object.assign(s, want); sessionWrites++; q.push(R.categoryChange); }
    if (!fixed || !s.speaker) { s.speaker = true; sessionWrites++; q.push(R.override); }
  };
  configure(); // CallKit didActivate
  let n = 0;
  while (q.length && n++ < cap) {
    const reason = q.shift()!;
    if (fixed && !DEVICE.has(reason)) continue;
    configure();
  }
  return { reconfigs, sessionWrites, looped: q.length > 0 };
}

test("old handler: setCategory/override route changes feed back forever (the volume pumping)", () => {
  const r = sim(false, []);
  assert.ok(r.looped && r.reconfigs > 100, JSON.stringify(r));
});

test("0.3.12: activation configures once; self-caused route changes never reconfigure", () => {
  const r = sim(true, []);
  assert.deepEqual(r, { reconfigs: 1, sessionWrites: 2, looped: false });
});

test("0.3.12: WebKit re-config + override storm during ring/call → zero extra reconfigs", () => {
  const r = sim(true, [R.config, R.categoryChange, R.override, R.config, R.override]);
  assert.equal(r.reconfigs, 1);
  assert.equal(r.looped, false);
});

test("0.3.12: real device change (AirPods in/out) reconfigures exactly once each, no writes when already right", () => {
  const r = sim(true, [R.newDevice, R.oldDeviceGone]);
  assert.equal(r.reconfigs, 3);
  assert.equal(r.sessionWrites, 2, "idempotent: nothing rewritten");
  assert.equal(r.looped, false);
});

test("Swift: route handler filters by reason before reconfiguring", () => {
  assert.match(SWIFT, /case \.newDeviceAvailable, \.oldDeviceUnavailable, \.wakeFromSleep, \.noSuitableRouteForCategory: return true/);
  assert.match(SWIFT, /guard Self\.isDeviceRouteChange\(why\) else \{ return \}\s*\n\s*if self\.savedAudio != nil \{ self\.configureAudio\(\) \}/);
});

test("Swift: configureAudio is idempotent (category/mode/options, sample rate, IO buffer, speaker override)", () => {
  assert.match(SWIFT, /if s\.category != \.playAndRecord \|\| s\.mode != mode \|\| s\.categoryOptions != opts \{/);
  assert.match(SWIFT, /if s\.preferredSampleRate != 48_000/);
  assert.match(SWIFT, /if wantSpeaker != onSpeaker \{/);
  assert.doesNotMatch(SWIFT, /setInputGain|isInputGainSettable|inputGain/);
});

test("Swift: configured once at activation — not after connect; speaker tap only overrides the port", () => {
  const connected = SWIFT.slice(SWIFT.indexOf('case "call:connected":'), SWIFT.indexOf('case "call:ended":'));
  assert.doesNotMatch(connected, /configureAudio\(\)/);
  const route = SWIFT.slice(SWIFT.indexOf('case "call:audioRoute":'), SWIFT.indexOf("default:", SWIFT.indexOf('case "call:audioRoute":')));
  assert.match(route, /applySpeakerOverride\(\)/);
  assert.doesNotMatch(route, /configureAudio\(\)/);
});

test("Swift: native ringback starts on CallKit activation for an unconnected outgoing call, stops on connect/end", () => {
  const act = SWIFT.slice(SWIFT.indexOf("didActivate audioSession"), SWIFT.indexOf("didDeactivate"));
  assert.match(act, /!\$0\.incoming && !\$0\.ended && !\$0\.answered && !\$0\.connected[\s\S]{0,20}startRingback\(\)/);
  const connected = SWIFT.slice(SWIFT.indexOf('case "call:connected":'), SWIFT.indexOf('case "call:ended":'));
  assert.match(connected, /stopRingback\(\)/);
  const ended = SWIFT.slice(SWIFT.indexOf('case "call:ended":'), SWIFT.indexOf('case "call:muted":'));
  assert.match(ended, /stopRingback\(\)/);
  assert.match(SWIFT, /p\.numberOfLoops = -1/);
});

test("ringback WAV generator matches a reference (2 s on / 4 s off, 440+480 Hz, valid RIFF)", () => {
  // TS port of OLCallManager.ringbackWav(); proves the tone/cadence/header math the Swift uses
  const rate = 48_000, n = rate * 6, on = rate * 2, fade = rate / 100;
  const pcm = new Int16Array(n);
  for (let i = 0; i < n; i++) if (i < on) { const t = i / rate, env = Math.min(1, Math.min(i, on - i) / fade); pcm[i] = Math.round(Math.max(-1, Math.min(1, 0.22 * env * (Math.sin(2 * Math.PI * 440 * t) + Math.sin(2 * Math.PI * 480 * t)))) * 32767); }
  let peakOn = 0, peakOff = 0;
  for (let i = 0; i < n; i++) i < on ? (peakOn = Math.max(peakOn, Math.abs(pcm[i]))) : (peakOff = Math.max(peakOff, Math.abs(pcm[i])));
  assert.ok(peakOn > 12_000 && peakOn < 32_767, `on-phase peak ${peakOn}, no clipping`);
  assert.equal(peakOff, 0);
  assert.match(SWIFT, /let rate = 48_000, seconds = 6, n = rate \* seconds, on = rate \* 2, fade = rate \/ 100/);
  assert.match(SWIFT, /u32\(UInt32\(36 \+ pcm\.count\)\)/);
});

test("0.3.13: ringback watchdog restarts a stopped player, reports status, honours web takeover", () => {
  assert.match(SWIFT, /Timer\(timeInterval: 1\.0, repeats: true\)[\s\S]{0,80}ringbackTick\(\)/);
  const tick = SWIFT.slice(SWIFT.indexOf("private func ringbackTick()"), SWIFT.indexOf("private func reportRingback"));
  assert.match(tick, /guard wantRingback else \{ return stopRingback\(\) \}/);
  assert.match(tick, /ringback\?\.isPlaying != true[\s\S]{0,160}playRingback\(\)/);
  assert.match(SWIFT, /AVAudioSession\.interruptionNotification/);
  // Current Swift expresses the same condition in two readable guards: interruption-ended, then ringback ownership.
  assert.match(SWIFT, /InterruptionType\(rawValue: raw\) == \.ended[\s\S]{0,100}if self\.wantRingback \{ self\.playRingback\(\) \}/);
  assert.match(SWIFT, /emit\(\["type": "ringback", "playing": playing\]\)/);
  assert.match(SWIFT, /case "call:ringbackStop":\s*\n\s*webOwnsRingback = true\s*\n\s*stopRingback\(\)/);
  assert.match(SWIFT, /!webOwnsRingback && calls\.values\.contains \{ !\$0\.incoming && !\$0\.ended && !\$0\.answered && !\$0\.connected \}/);
});

test("0.3.13: watchdog model — player stopped by a session change at t=1.2 s is playing again within 1 s, for the whole ring", () => {
  // discrete model of ringbackTick(): each 1 s tick restarts a stopped player while the call is outgoing
  let playing = true, silentMs = 0, maxGap = 0;
  const kills = new Set([1200, 1900, 7300]); // WebKit mic capture, WebRTC unit start, a later route/session change
  for (let t = 0; t <= 45_000; t += 100) {
    if (kills.has(t)) playing = false;
    if (t % 1000 === 0 && !playing) playing = true; // tick
    silentMs = playing ? 0 : silentMs + 100;
    maxGap = Math.max(maxGap, silentMs);
  }
  assert.ok(maxGap <= 1000, `max silence ${maxGap} ms`);
});
