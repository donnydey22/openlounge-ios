// Simulated SFU + native RTP counter: peer starts sending 2-3 s late, pauses mid-call, resumes.
import { createAudioWatch } from '../src/audioWatch';
import assert from 'node:assert';
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function call(dir: string, i: number) {
  const delay = 2000 + Math.random() * 1000; const t0 = Date.now(); let rx = 0, pt = 100, restarts = 0, consumes = 0;
  let sending = false; const peer = setTimeout(() => (sending = true), delay);
  const pump = setInterval(() => { if (sending && pt === 111) rx += 5; }, 100);
  const logs: string[] = [];
  const w = createAudioWatch({ consume: async () => (consumes++, sending ? { payloadType: 111 } : null),
    rxPackets: () => rx, restart: (p) => { pt = p; restarts++; rx = 0; }, currentPt: () => pt, log: (m) => logs.push(m) });
  while (!logs.some((l) => l.includes('flowing'))) { assert(Date.now() - t0 < 10000, `${dir}#${i} never got audio`); await sleep(50); }
  const first = Date.now() - t0;
  sending = false; await sleep(3500); assert(logs.some((l) => l.includes('stopped')), 'stall not detected');
  const c = consumes; sending = true; await sleep(1500);
  assert(logs.filter((l) => l.includes('flowing')).length >= 2, 'did not resume');
  w.stop(); clearInterval(pump); clearTimeout(peer);
  console.log(`${dir} #${i}: peer delay ${Math.round(delay)} ms -> audio at ${first} ms, restarts=${restarts}, resumed after mid-call stall OK`);
}
(async () => { for (const dir of ['Android->iPhone', 'iPhone->Android']) for (let i = 1; i <= 5; i++) await call(dir, i); console.log('ALL 10 PASS'); })()
  .catch((e) => { console.error('FAIL', e.message); process.exit(1); });
