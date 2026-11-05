// @ts-nocheck -- Node's built-in test runner.
import assert from 'node:assert/strict';
import test from 'node:test';
import { BUTTONS, stateFor, statusText, takesOver } from '../src/nativeCallFlow.ts';

test('page call messages map to Telegram PresentationCall states, nothing else', () => {
  assert.equal(stateFor('call:outgoing'), 'waiting');
  assert.equal(stateFor('call:answering'), 'connecting');
  assert.equal(stateFor('call:connected'), 'active');
  assert.equal(stateFor('call:ended'), 'terminated');
  assert.equal(stateFor('call:stats'), null);
  assert.equal(stateFor('call:muted'), null);
});
test('status text + timer', () => {
  assert.equal(statusText('waiting', 0), 'Calling…');
  assert.equal(statusText('connecting', 0), 'Connecting…');
  assert.equal(statusText('active', 65), '1:05');
  assert.equal(statusText(null, 0), '');
});
test('gate: audio calls with a callId only; video keeps the web screen', () => {
  assert.equal(takesOver({ type: 'call:outgoing', callId: 'abc', video: false }), true);
  assert.equal(takesOver({ type: 'call:answering', callId: 'abc' }), true);
  assert.equal(takesOver({ type: 'call:outgoing', callId: 'abc', video: true }), false);
  assert.equal(takesOver({ type: 'call:outgoing' }), false);
  assert.equal(takesOver({ type: 'call:incoming', callId: 'abc' }), false);
});
test('buttons row = CallControllerButtonsNode .active order', () => {
  assert.deepEqual([...BUTTONS], ['camera', 'speaker', 'mute', 'end']);
});
