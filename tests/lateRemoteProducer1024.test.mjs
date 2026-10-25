// FX-063 must-pass: Keiko's producer shows up ~10 s after answer and the consume is slow (4.2 s on cellular, call
// 4853a217). The native iPhone must still create + resume her video consumer instead of stopping on an empty consume.
import test from 'node:test'; import assert from 'node:assert/strict'; import fs from 'node:fs';
import { pollConsumers } from '../src/consumeUntil.ts';
const sim = ({ producerAt, consumeMs, video = true }) => {
  let t = 0; const consumers = []; const calls = [];
  const sleep = async (ms) => { t += ms; };
  const sync = async () => { const start = t; t += consumeMs; calls.push(start);
    if (start >= producerAt) for (const k of video ? ['audio', 'video'] : ['audio']) if (!consumers.includes(k)) consumers.push(k); };
  return { now: () => t, sleep, sync, consumers, calls, get t() { return t; } };
};
test('late producer (10 s after answer) + slow consume (4.2 s): video consumer is created', async () => {
  const s = sim({ producerAt: 10_000, consumeMs: 4_200 });
  const ok = await pollConsumers({ sync: s.sync, now: s.now, sleep: s.sleep, closed: () => false,
    done: () => s.consumers.includes('audio') && s.consumers.includes('video') });
  assert.equal(ok, true);
  assert.ok(s.consumers.includes('video'));
  assert.ok(s.calls.length > 1, 'an empty first consume must not end the retry');
  assert.ok(s.t < 20_000, `video within 20 s, got ${s.t}`);
});
test('empty consume never counts as success; stops when the call closes', async () => {
  const s = sim({ producerAt: Infinity, consumeMs: 300 }); let closed = false;
  const ok = await pollConsumers({ sync: async () => { await s.sync(); if (s.calls.length === 3) closed = true; },
    now: s.now, sleep: s.sleep, closed: () => closed, done: () => s.consumers.length > 0 });
  assert.equal(ok, false); assert.equal(s.calls.length, 3);
});
test('consume errors are retried, budget bounds the loop', async () => {
  let n = 0; let t = 0;
  const ok = await pollConsumers({ sync: async () => { n++; t += 100; throw new Error('x'); }, now: () => t,
    sleep: async (ms) => { t += ms; }, closed: () => false, done: () => false, budgetMs: 10_000 });
  assert.equal(ok, false); assert.ok(n >= 5 && n <= 10);
});
test('nativeMedia wires the poller and diagnostics', () => {
  const s = fs.readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
  assert.match(s, /done: \(\) => this\.hasRemote\('audio'\) && \(!this\.nativeVideo \|\| this\.hasRemote\('video'\)\)/);
  assert.match(s, /this\.diag\('consume-result'/);
  assert.match(s, /'first-remote-video-frame'/);
  assert.match(s, /void this\.watchFirstFrame\(c\)/);
  assert.match(s, /this\.syncAgain = true;\n\s*return this\.syncing/); // consumerAvailable during a slow consume re-runs
});
// Held behaviour: replay of the Oct 23 successful iPhone video calls (c4c780d7: first consume empty, Keiko's audio
// +1.7 s, video +3.1 s; 89a7c572 / 8ea1c4ac: both ready at the first consume). Both must still end with audio+video.
test('Oct 23 successful-call timelines still produce audio + video', async () => {
  for (const [audioAt, videoAt] of [[1_700, 3_100], [0, 0]]) {
    let t = 0; const have = new Set();
    const ok = await pollConsumers({
      sync: async () => { t += 120; if (t >= audioAt) have.add('audio'); if (t >= videoAt) have.add('video'); },
      now: () => t, sleep: async (ms) => { t += ms; }, closed: () => false, done: () => have.has('audio') && have.has('video') });
    assert.equal(ok, true); assert.ok(t < 6_000, `held timeline took ${t} ms`);
  }
});
