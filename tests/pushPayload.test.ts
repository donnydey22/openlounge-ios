// @ts-nocheck -- this is executed by Node's built-in test runner; the Expo app tsconfig intentionally omits Node globals.
import assert from 'node:assert/strict';
import test from 'node:test';
import { foregroundPushData, shouldForwardForegroundPush } from '../src/pushPayload';
import { ForegroundPushQueue } from '../src/foregroundPushQueue';

test('keeps bounded string FCM data for the WebView event boundary', () => {
  const data = foregroundPushData({ type: 'dm', title: 'Maya', badge: '3', ignored: 7, extra: 'x'.repeat(1025) });
  assert.deepEqual(data, { type: 'dm', title: 'Maya', badge: '3' });
});

test('reserves native call events for CallKit while forwarding notification and clear updates', () => {
  assert.equal(shouldForwardForegroundPush({ type: 'call_incoming' }), false);
  assert.equal(shouldForwardForegroundPush({ type: 'call_cancel' }), false);
  assert.equal(shouldForwardForegroundPush({ type: 'dm', tag: 'dm:u_maya' }), true);
  assert.equal(shouldForwardForegroundPush({ type: 'clear', clear: '1', tag: 'dm:u_maya' }), true);
});

test('retains distinct transition-time updates while collapsing the latest update for one tag', () => {
  const queue = new ForegroundPushQueue();
  queue.enqueue({ type: 'dm', tag: 'dm:u_maya', badge: '3' });
  queue.enqueue({ type: 'roomInvite', tag: 'room:r_1', badge: '4' });
  queue.enqueue({ type: 'clear', clear: '1', tag: 'dm:u_maya', badge: '2' });
  assert.deepEqual(queue.drain(), [
    { type: 'roomInvite', tag: 'room:r_1', badge: '4' },
    { type: 'clear', clear: '1', tag: 'dm:u_maya', badge: '2' },
  ]);
  assert.deepEqual(queue.drain(), []);
});
