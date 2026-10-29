export type ForegroundPushData = Record<string, string>;

/** Keep only string FCM data fields before crossing into the WebView's event boundary. */
export function foregroundPushData(data: Record<string, unknown> | undefined): ForegroundPushData {
  const out: ForegroundPushData = {};
  if (!data) return out;
  for (const [key, value] of Object.entries(data)) {
    if (typeof value === 'string' && key.length <= 64 && value.length <= 1024) out[key] = value;
  }
  return out;
}

/** Calls retain their dedicated CallKit/VoIP path; every other data event can use the web banner reconciliation path. */
export function shouldForwardForegroundPush(data: ForegroundPushData): boolean {
  return data.type !== 'call_incoming' && data.type !== 'call_cancel';
}
