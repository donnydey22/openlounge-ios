import * as LocalAuthentication from 'expo-local-authentication';
import * as SecureStore from 'expo-secure-store';

// Opt-in biometric app lock — a convenience layer over the Keychain session (sessionStore.ts); nothing is signed
// out, the lock only gates the UI. Face ID / Touch ID with the device passcode as fallback.
// No device security at all (no passcode) → unavailable → the setting is off and cannot be enabled.

export { LOCK_AFTER_MS, shouldLock } from './lockPolicy';
const KEY = 'openlounge.biometricLock';
const OPTS: SecureStore.SecureStoreOptions = {
  keychainService: 'com.donnydey.openlounge.prefs',
  keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
};

export type AuthStatus = 'success' | 'cancelled' | 'failed' | 'unavailable';

/** Device has biometrics or at least a passcode. */
export async function isAvailable(): Promise<boolean> {
  try {
    const level = await LocalAuthentication.getEnrolledLevelAsync();
    return level !== LocalAuthentication.SecurityLevel.NONE;
  } catch {
    return false;
  }
}

export async function getEnabled(): Promise<boolean> {
  try {
    const v = await SecureStore.getItemAsync(KEY, OPTS);
    return v === '1' && (await isAvailable());
  } catch {
    return false;
  }
}

export async function setEnabledFlag(on: boolean): Promise<void> {
  if (on) await SecureStore.setItemAsync(KEY, '1', OPTS);
  else await SecureStore.deleteItemAsync(KEY, OPTS);
}

/** Face ID / Touch ID, passcode fallback ("Enter Passcode" in the system sheet). */
export async function authenticate(promptMessage: string): Promise<AuthStatus> {
  if (!(await isAvailable())) return 'unavailable';
  try {
    const r = await LocalAuthentication.authenticateAsync({
      promptMessage,
      fallbackLabel: 'Use Passcode',
      cancelLabel: 'Cancel',
      disableDeviceFallback: false,
    });
    if (r.success) return 'success';
    const e = r.error;
    if (e === 'user_cancel' || e === 'system_cancel' || e === 'app_cancel') return 'cancelled';
    if (e === 'not_enrolled' || e === 'not_available' || e === 'passcode_not_set') return 'unavailable';
    return 'failed';
  } catch {
    return 'failed';
  }
}

/** setEnabled(true) needs a successful prompt first; returns the resulting state. */
export async function setEnabled(on: boolean): Promise<boolean> {
  if (!on) {
    await setEnabledFlag(false);
    return false;
  }
  const s = await authenticate('Turn on app lock');
  if (s === 'success') await setEnabledFlag(true);
  return getEnabled();
}
