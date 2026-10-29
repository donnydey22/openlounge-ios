// Native Firebase phone verification for the web AuthFlow (window.OpenLoungeNative.phoneAuthStart/Confirm).
// @react-native-firebase/auth verifies the app with a silent APNs push (APNs auth key is already in Firebase);
// if APNs isn't available (simulator / notifications blocked) the SDK falls back to a reCAPTCHA in
// SFSafariViewController, returning via the app-ID URL scheme (plugins/withFirebasePhoneAuthScheme.js).
// The resulting Firebase ID token goes back to the page, which posts it to the existing server endpoint
// (auth:verifyFirebase), so account matching is unchanged. The native Firebase user is signed out right away.
import { getApp } from '@react-native-firebase/app';
import { getAuth, signInWithPhoneNumber, signOut, type ConfirmationResult, type User } from '@react-native-firebase/auth';

export interface PhoneAuthResult {
  id: string;
  ok: boolean;
  sent?: boolean;
  idToken?: string;
  code?: string;
  error?: string;
}

let confirmation: ConfirmationResult | null = null;

const auth = () => getAuth(getApp());

function failure(id: string, e: unknown): PhoneAuthResult {
  const code = (e as { code?: string })?.code ?? 'auth/unknown';
  return { id, ok: false, code: code.startsWith('auth/') ? code : `auth/${code}` };
}

async function tokenAndSignOut(id: string, user: User | null | undefined): Promise<PhoneAuthResult> {
  if (!user) return { id, ok: false, code: 'auth/no-user' };
  const idToken = await user.getIdToken(true);
  await signOut(auth()).catch(() => {});
  confirmation = null;
  return { id, ok: true, idToken };
}

export async function phoneAuthStart(id: string, phone: string): Promise<PhoneAuthResult> {
  try {
    confirmation = await signInWithPhoneNumber(auth(), phone);
    return { id, ok: true, sent: true };
  } catch (e) {
    return failure(id, e);
  }
}

export async function phoneAuthConfirm(id: string, code: string): Promise<PhoneAuthResult> {
  if (!confirmation) return { id, ok: false, code: 'auth/missing-verification-id', error: 'Request a new code and try again.' };
  try {
    const cred = await confirmation.confirm(code);
    return await tokenAndSignOut(id, cred?.user);
  } catch (e) {
    return failure(id, e);
  }
}
