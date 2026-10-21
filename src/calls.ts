// Native call ringing (build 18): JS side of modules/openlounge-calls (PushKit + CallKit, iOS only).
//
// Launch safety: the native module is looked up lazily and every call is wrapped, so a build without the module
// (Expo Go, Android) simply has no native calls and the page keeps its in-page ring screen.
import { requireOptionalNativeModule } from 'expo';

export type CallAction =
  | { type: 'answer'; callId: string; video?: boolean; at?: number }
  | { type: 'decline'; callId: string; at?: number }
  | { type: 'hangup'; callId: string; at?: number }
  | { type: 'mute'; muted: boolean; at?: number }
  /** CallKit activated the audio session: page audio (ringback / ringtone) must be resumed */
  | { type: 'audio'; reason: string; at?: number };

type Sub = { remove(): void };
type NativeCalls = {
  ready(): string;
  getVoipToken(): string;
  handlePageMessage(json: string): void;
  setAuth(token: string, expMs: number): void;
  endCall(callId: string, reason: string): void;
  addListener(event: 'onCallAction', fn: (e: { json: string }) => void): Sub;
  addListener(event: 'onVoipToken', fn: (e: { token: string }) => void): Sub;
};

let mod: NativeCalls | null | undefined;
function native(): NativeCalls | null {
  if (mod !== undefined) return mod;
  try {
    mod = requireOptionalNativeModule<NativeCalls>('OpenLoungeCalls');
  } catch {
    mod = null;
  }
  return mod;
}

export const nativeCallsAvailable = (): boolean => native() != null;

const CALL_ID = /^[A-Za-z0-9_-]{1,64}$/;

export function parseCallAction(raw: unknown): CallAction | null {
  try {
    const a = (typeof raw === 'string' ? JSON.parse(raw) : raw) as Record<string, unknown>;
    if (!a || typeof a.type !== 'string') return null;
    if (a.type === 'audio') return { type: 'audio', reason: typeof a.reason === 'string' ? a.reason.slice(0, 40) : 'callkit' };
    // Actual output route (Speaker/Phone button truth). Previously dropped here, so the page never learned the route.
    if (a.type === 'audioRoute') return { type: 'audioRoute', headset: a.headset === true, speaker: a.speaker === true, port: typeof a.port === 'string' ? a.port.slice(0, 40) : '', name: typeof a.name === 'string' ? a.name.slice(0, 80) : '', reason: typeof a.reason === 'number' ? a.reason : 0 } as unknown as CallAction;
    if (a.type === 'mute') return typeof a.muted === 'boolean' ? { type: 'mute', muted: a.muted } : null;
    if ((a.type === 'answer' || a.type === 'decline' || a.type === 'hangup') && typeof a.callId === 'string') {
      if (a.type !== 'hangup' && !CALL_ID.test(a.callId)) return null;
      return a.type === 'answer' ? { type: 'answer', callId: a.callId, video: a.video === true } : { type: a.type, callId: a.callId };
    }
    return null;
  } catch {
    return null;
  }
}

/** Subscribes to CallKit actions + PushKit token changes; returns pending actions from before JS was up (cold start). */
export function startNativeCalls(onAction: (a: CallAction) => void, onToken: (token: string) => void): { pending: CallAction[]; stop: () => void } {
  const n = native();
  if (!n) return { pending: [], stop: () => {} };
  const subs: Sub[] = [];
  try {
    subs.push(n.addListener('onCallAction', (e) => {
      const a = parseCallAction(e?.json);
      if (a) onAction(a);
    }));
    subs.push(n.addListener('onVoipToken', (e) => onToken(typeof e?.token === 'string' ? e.token : '')));
  } catch (e) {
    console.warn('[calls] listeners failed (ignored):', e);
  }
  let pending: CallAction[] = [];
  try {
    const arr = JSON.parse(n.ready()) as unknown[];
    pending = (Array.isArray(arr) ? arr : []).map(parseCallAction).filter((a): a is CallAction => a != null);
  } catch {}
  return { pending, stop: () => subs.forEach((s) => s.remove()) };
}

export function getVoipToken(): string {
  try {
    return native()?.getVoipToken() ?? '';
  } catch {
    return '';
  }
}

export function forwardPageCallMessage(msg: Record<string, unknown>): void {
  try {
    native()?.handlePageMessage(JSON.stringify(msg));
  } catch {}
}

/** Mirrors the session's short-lived access token for native Decline (no refresh natively: refresh tokens rotate). */
export function syncCallAuthFromSession(sessionJson: string | null): void {
  const n = native();
  if (!n) return;
  const a = accessFromSession(sessionJson);
  try {
    n.setAuth(a?.access ?? '', a?.exp ?? 0);
  } catch {}
}

export function endNativeCall(callId: string, reason: string): void {
  try {
    if (CALL_ID.test(callId)) native()?.endCall(callId, reason);
  } catch {}
}

/** URL the WebView opens when a call is answered from CallKit (NATIVE_SPEC §2: idempotent, safe to open twice). */
export function acceptUrl(origin: string, callId: string): string {
  return `${origin.replace(/\/+$/, '')}/call/${encodeURIComponent(callId)}?accept=1`;
}

/**
 * PushKit token → server (NATIVE_SPEC §2). Uses the session's access token mirrored from setSession, so it runs after
 * sign-in and after every refresh-token rotation; Ad Hoc / App Store builds use the production APNs environment.
 */
export async function postVoipToken(origin: string, token: string, access: string, remove = false): Promise<number> {
  if (!/^[0-9a-f]{64,200}$/.test(token) || !access) return 0;
  try {
    const r = await fetch(`${origin.replace(/\/+$/, '')}${remove ? '/api/push/voip-token/remove' : '/api/push/voip-token'}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${access}` },
      body: JSON.stringify(remove ? { token } : { token, env: __DEV__ ? 'sandbox' : 'production' }),
    });
    return r.status;
  } catch {
    return 0;
  }
}

/** {access, accessExp} from the opaque session JSON (bridge.ts contract), or null. */
export function accessFromSession(sessionJson: string | null): { access: string; exp: number } | null {
  try {
    const v = sessionJson ? (JSON.parse(sessionJson) as { access?: unknown; accessExp?: unknown }) : null;
    if (v && typeof v.access === 'string' && v.access && typeof v.accessExp === 'number') return { access: v.access, exp: v.accessExp };
  } catch {}
  return null;
}
