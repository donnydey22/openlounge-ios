// build 72: page Accept → CallKit answered at the tap (no ring over the live call); server "answered" cancel ignored on the answering iPhone.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const bridge = readFileSync('src/bridge.ts', 'utf8');
const mgr = readFileSync('modules/openlounge-calls/ios/OLCallManager.swift', 'utf8');
test('bridge passes call:answering with callId', () => assert.match(bridge, /case 'call:answering':\s*\n\s*return id \? wrap\(\{ type: 'call:answering', callId: id/));
test('manager answers CallKit on call:answering', () => assert.match(mgr, /case "call:answering":[\s\S]{0,900}pageAnswered\.insert\(callId\)[\s\S]{0,300}c\.answeredInPage = true\s*controller\.request\(CXTransaction\(action: CXAnswerCallAction/));
test('answered cancel ignored on the device that answered', () => assert.match(mgr, /func endExternally[\s\S]{0,400}if reason == "answered" && pageAnswered\.contains\(callId\) \{ return \}/));
test('connected path unchanged', () => assert.match(mgr, /case "call:connected":\s*stopRingback\(\)/));
test('answered-here flag persists and covers the CallKit UI answer', () => {
  assert.match(mgr, /UserDefaults\.standard\.stringArray\(forKey: "ol\.answeredHere"\)/);
  assert.match(mgr, /perform action: CXAnswerCallAction[\s\S]{0,200}markAnsweredHere\(c\.callId\)/);
});
test('page failure ends CallKit as .failed', () => {
  assert.match(mgr, /"failed" \? \.failed : \.remoteEnded/);
  assert.match(bridge, /m\.reason === 'failed'/);
});
