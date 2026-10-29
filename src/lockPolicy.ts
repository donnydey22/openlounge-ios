// Pure lock policy (no native imports, unit-tested in scripts/check-bridge.cjs).
export const LOCK_AFTER_MS = 60_000; // resume after > 60 s in the background (configurable later)

/** backgroundedAt <= 0 means cold start. */
export function shouldLock(enabled: boolean, backgroundedAt: number, now: number, lockAfterMs = LOCK_AFTER_MS): boolean {
  if (!enabled) return false;
  if (backgroundedAt <= 0) return true;
  return now - backgroundedAt > lockAfterMs;
}

/** Report presence:visible only when the app is active and App Lock is not covering the WebView. */
export function shouldReportVisible(appActive: boolean, lock: 'checking' | 'locked' | 'unlocked'): boolean {
  return appActive && lock === 'unlocked';
}

/** /call/<id> or /call/<id>?accept=1 — bypass App Lock so Accept can join. */
export function isCallAcceptPath(pathOrUrl: string | null | undefined): boolean {
  if (!pathOrUrl) return false;
  let path = pathOrUrl;
  try {
    if (path.includes('://')) path = new URL(path).pathname + (new URL(path).search || '');
  } catch {
    /* keep raw */
  }
  if (!path.startsWith('/call/')) return false;
  if (path.includes('accept=1')) return true;
  const base = path.split('?')[0] ?? path;
  return base.length > '/call/'.length && !base.slice('/call/'.length).includes('/');
}
