import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const r = (p) => readFileSync(p, 'utf8');
const na = r('modules/openlounge-calls/ios/OLNativeAudio.swift'), b82na = r('tests/fixtures/b82-OLNativeAudio.swift');
const m = r('modules/openlounge-calls/ios/OLCallManager.swift'), b82m = r('tests/fixtures/b82-OLCallManager.swift'), b83m = r('tests/fixtures/b83-OLCallManager.swift');
const lane = r('modules/openlounge-calls/ios/OLNativeAudioLane.swift');
const cut = (s, a, b) => { const i = s.indexOf(a); assert.ok(i >= 0, a); const j = s.indexOf(b, i + a.length); assert.ok(j > i, b); return s.slice(i, j); };
test('check 2: Android→iPhone incoming start sequence byte-identical to b82', () => {
  assert.equal(cut(na, 'static func laneActivate', 'static var isEnabled'), cut(b82na, 'static func laneActivate', 'static var isEnabled'));
  const da = (s) => cut(s, 'public func provider(_ provider: CXProvider, didActivate', 'public func provider(_ provider: CXProvider, didDeactivate');
  assert.equal(da(m), da(b82m));
});
test('check 3: call end tears down lane, audio unit, session and flags', () => {
  const t = cut(m, 'private func teardownCallAudio', '\n  }\n');
  for (const x of ['OLNativeAudioLane.shared?.close()', 'OLNativeAudioLane.resetActivation()', 'laneActivatedCall = nil', 'laneReactivating = false', 'nativeAudioOn = false', 'callKitAudioActive = false', 'OLNativeAudio.laneTeardown()']) assert.ok(t.includes(x), x);
  const lt = cut(na, 'static func laneTeardown', 'static func didDeactivate');
  assert.match(lt, /isAudioEnabled = false[\s\S]*setActive\(false, options: \.notifyOthersOnDeactivation\)[\s\S]*audioSessionDidDeactivate/);
  assert.match(cut(m, 'private func resetAudioState', 'private func teardownCallAudio'), /guard !hasLiveCall[\s\S]*if why != \"ringtone-prepare\" \{ teardownCallAudio\(why\) \}/);
});
test('check 4: redial starts from zero (activation flag cleared; next lane call waits for its own didActivate; teardown never hits a new live call)', () => {
  assert.match(cut(lane, 'static func resetActivation', '\n  }\n'), /activated = false/);
  assert.match(cut(m, 'private func teardownCallAudio', 'OLNativeAudio.laneTeardown()'), /guard let self = self, !self\.hasLiveCall else \{ return \}/);
  assert.match(lane, /if !Self\.activated \{ rtc\.isAudioEnabled = false \}/);
});
test('check 5: iPhone outgoing CallKit cell identical to b83', () => {
  for (const [a, b] of [['case "call:outgoing":', 'case "call:connected":'], ['public func provider(_ provider: CXProvider, perform action: CXStartCallAction)', 'public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction)']])
    assert.equal(cut(m, a, b), cut(b83m, a, b));
  assert.equal(r('modules/openlounge-calls/ios/OLTelecomCore.swift').includes('includesCallsInRecents = false'), true);
});

test('check 3b: per-cell teardown — every call-end path of every cell reaches resetAudioState → teardownCallAudio', () => {
  for (const w of ['ring-end', 'provider-reset', 'end-action', 'page-ended']) assert.ok(m.includes(`resetAudioState("${w}")`), w);
  // end-action covers CallKit hangup for incoming lane, incoming iPhone and outgoing calls; page-ended covers remote/page hangup
  const ea = cut(m, 'perform action: CXEndCallAction', 'perform action: CXSetMutedCallAction');
  assert.match(ea, /resetAudioState\("end-action"\)/);
  assert.doesNotMatch(cut(m, 'private func teardownCallAudio', 'OLNativeAudio.laneTeardown()'), /isLaneCall|isAndroidCall|incoming|callVideo/);
});

test('check 8: CXProvider configuration re-set immediately before EVERY reportNewIncomingCall', () => {
  const sites = m.split('reportNewIncomingCall(').length - 1;
  const guarded = (m.match(/provider\.configuration = provider\.configuration\n\s*provider\.reportNewIncomingCall\(/g) || []).length;
  assert.ok(sites >= 1); assert.equal(guarded, sites);
});
