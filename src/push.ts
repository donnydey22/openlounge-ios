// CONTROL BUILD (b13-nopush): push/Firebase native modules removed entirely for crash bisecting. All no-ops.
export type PushTokenListener = (token: string) => void;
export function initPush(): boolean {
  return false;
}
export async function requestPushPermissionAndToken(): Promise<string> {
  return '';
}
export function onTokenRefresh(_cb: PushTokenListener): () => void {
  return () => {};
}
export function onNotificationOpen(_cb: (path: string) => void): () => void {
  return () => {};
}
export async function clearDelivered(_tag: string) {}
