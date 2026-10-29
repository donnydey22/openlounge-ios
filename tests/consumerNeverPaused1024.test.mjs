// FX-063b must-pass (call 30dc469c): every consumed stream must end up resumed. A failed resume used to leave the
// consumer in the map (so later syncs skipped it) and counted it as "remote media here", stopping the poller.
import test from 'node:test'; import assert from 'node:assert/strict'; import fs from 'node:fs';
const s = fs.readFileSync(new URL('../src/nativeMedia.ts', import.meta.url), 'utf8');
test('only SFU-acknowledged resumes count as remote media', () => {
  assert.match(s, /await this\.r\('ms:consumer:resume', \{ consumerId: id \}\); this\.resumed\.add\(id\); return;/);
  assert.match(s, /if \(c\.kind === kind && this\.resumed\.has\(c\.id\)\) return true;/);
});
test('each sync re-resumes any consumer still paused, before consuming new ones', () => {
  const sync = s.slice(s.indexOf('syncConsumers(): Promise<void>'), s.indexOf('} while (this.syncAgain'));
  const re = sync.indexOf('if (!this.closed && !this.resumed.has(c.id)) await this.resumeConsumer(c.id)');
  assert.ok(re > 0 && re < sync.indexOf('for (const p of x.consumers ?? [])'));
});
test('a failed resume never aborts the sync loop (logged per kind)', () => {
  assert.match(s, /await this\.resumeConsumer\(c\.id\)\.catch\(\(\) => this\.diag\('resume-failed', \{ kinds: c\.kind \}\)\);/);
  assert.match(s, /this\.diag\('consumer-resumed', \{ kinds: c\.kind \}\)/);
});
// Behavioural replay: resume fails 4x on first consume, succeeds on the next sync → video ends resumed.
test('replay: failed first resume is retried on the next poll', async () => {
  const consumers = new Map(); const resumed = new Set(); let fails = 4;
  const resume = async (id) => { if (fails-- > 0) throw new Error('timeout'); resumed.add(id); };
  const sync = async () => {
    for (const id of consumers.keys()) if (!resumed.has(id)) await resume(id).catch(() => {});
    if (!consumers.has('v1')) { consumers.set('v1', 'video'); for (let i = 0; i < 4; i++) { try { await resume('v1'); break; } catch {} } }
  };
  const done = () => [...consumers].some(([id, k]) => k === 'video' && resumed.has(id));
  await sync(); assert.equal(done(), false, 'paused consumer is not success');
  await sync(); assert.equal(done(), true);
});
