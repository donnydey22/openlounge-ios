// FX-063 (Oct 24): a late remote producer must still reach the native iPhone. Call 4853a217: the first consume ran
// before Keiko's Android page had produced, returned nothing, and the one-shot retry stopped on that "success". Poll
// until the wanted consumers exist (or the call ends / budget runs out). Pure: no RN imports, so it is unit-testable.
export type PollOpts = {
  sync: () => Promise<void>;
  done: () => boolean;
  closed: () => boolean;
  intervalMs?: number;
  budgetMs?: number;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
};
export async function pollConsumers(o: PollOpts): Promise<boolean> {
  const now = o.now ?? Date.now;
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const interval = o.intervalMs ?? 1500;
  const end = now() + (o.budgetMs ?? 45_000);
  while (!o.closed()) {
    try { await o.sync(); } catch {}
    if (o.closed()) return false;
    if (o.done()) return true;
    if (now() >= end) return false;
    await sleep(interval);
  }
  return false;
}
