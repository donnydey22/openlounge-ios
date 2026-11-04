/** Remote-audio watchdog. Ticks every `everyMs` until stop(): no cap, no window. "Flowing" = the native RX packet
 *  counter grew within `stallMs`. Not flowing → ms:plain:consume (idempotent on the SFU); a consumer whose PT differs
 *  from the leg's → restart the leg on it. Logs while waiting (never silent). */
export function createAudioWatch(o: {
  consume(): Promise<{ payloadType: number } | null>; rxPackets(): number; restart(pt: number): void; currentPt(): number;
  log(m: string): void; everyMs?: number; stallMs?: number; now?: () => number;
}) {
  const every = o.everyMs ?? 700, stall = o.stallMs ?? 2000, now = o.now ?? Date.now;
  let lastRx = -1, lastAt = 0, flowing = false, busy = false, stopped = false, waitLog = 0;
  const t0 = now();
  const tick = async () => {
    if (stopped || busy) return; busy = true;
    try {
      const rx = o.rxPackets();
      if (rx < lastRx) lastRx = rx; // counter reset by a leg restart
      if (rx > lastRx && rx > 0) { if (!flowing) o.log(`remote audio RTP flowing after ${now() - t0} ms`); lastRx = rx; lastAt = now(); flowing = true; return; }
      if (flowing && now() - lastAt < stall) return;
      if (flowing) { flowing = false; o.log('remote audio RTP stopped; polling again'); }
      const c = await o.consume();
      if (stopped) return;
      if (c && c.payloadType !== o.currentPt()) { o.log(`remote audio consumer pt=${c.payloadType}; restarting leg`); o.restart(c.payloadType); }
      if (now() - waitLog >= 5000) { waitLog = now(); o.log(`waiting for remote audio (${c ? 'consumer present, no RTP yet' : 'no consumer yet'})`); }
    } finally { busy = false; }
  };
  const h = setInterval(tick, every); void tick();
  return { stop() { stopped = true; clearInterval(h); }, tick };
}
