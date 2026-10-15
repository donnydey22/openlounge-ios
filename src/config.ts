import Constants from 'expo-constants';

import { parseUrl } from './url';

const extra = (Constants.expoConfig?.extra ?? {}) as { startUrl?: string };

/** The page the app opens. */
export const START_URL = extra.startUrl ?? 'https://openlounge.app';
export const START_ORIGIN = (() => {
  const p = parseUrl(START_URL);
  return p ? `https://${p.host}${p.port ? `:${p.port}` : ''}` : 'https://openlounge.app';
})();

/** Custom URL scheme (app.json `scheme`). The OAuth callback is openlounge://auth?code=… (server: APP_RETURN). */
export const APP_SCHEME = 'openlounge';
export const AUTH_CALLBACK = `${APP_SCHEME}://auth`;
/** Web page that redeems the one-time code with POST /auth/exchange (openlounge unified-auth branch). */
export const AUTH_COMPLETE_PATH = '/auth/complete';

/**
 * Hosts that stay inside the app (and may talk to the native bridge).
 * Everything else that is opened as a top-level page goes to SFSafariViewController.
 */
export const APP_HOSTS = new Set([
  parseUrl(START_URL)?.host ?? 'openlounge.app',
  'openlounge.app',
  'www.openlounge.app',
  'openlounge-production.up.railway.app',
]);

export const APP_VERSION = Constants.expoConfig?.version ?? '0';
/** Native build number (CFBundleVersion / eas buildNumber). */
export const APP_BUILD =
  Constants.nativeBuildVersion ??
  Constants.expoConfig?.ios?.buildNumber ??
  '0';

/** Theme colours of the web app (src/lib/theme.ts THEME_COLORS) and the native launch background. */
export const COLORS = {
  launch: '#1C1C1E', // android openlounge_bg (dark splash)
  launchLight: '#F4F3EE', // light splash
  dark: '#0b0b0d',
  light: '#f4f3ee',
  accent: '#F2B366',
  green: '#5B8C5A',
  textDark: '#FFFFFF', // text on dark
  mutedDark: '#A1A1A6',
  textLight: '#1C1C1E', // text on light
  mutedLight: '#6B6B70',
};

/**
 * The web app is built for an opaque status bar (Android wrapper, iOS "Add to Home Screen" with
 * statusBarStyle=default): its headers do not pad with env(safe-area-inset-top). So the WebView starts below the
 * status bar / Dynamic Island (that strip is painted in the page's theme colour) and env(safe-area-inset-top)
 * is 0 inside the page. The bottom stays edge-to-edge: the web already pads its bars with
 * env(safe-area-inset-bottom) for the home indicator. Flip to true once every web header uses
 * env(safe-area-inset-top).
 */
export const EDGE_TO_EDGE_TOP = true;

/**
 * 'overlay' (default): WKWebView behaviour — the keyboard overlays the page, the web composer follows
 *   window.visualViewport (src/app/messages/[peerId]/page.tsx already does) or --ol-keyboard-height.
 * 'resize': shrink the WebView above the keyboard like Android's adjustResize.
 */
export const KEYBOARD_MODE: 'overlay' | 'resize' = 'overlay';

/** Splash stays up at most this long (slow network); the page normally reports ready much sooner. */
export const SPLASH_MAX_MS = 8000;

export function isAppHost(host: string): boolean {
  return APP_HOSTS.has(host.toLowerCase());
}

/** https URL on one of the app's own hosts (default port, no user-info). */
export function isAppUrl(raw: string): boolean {
  const u = parseUrl(raw);
  return !!u && u.scheme === 'https' && !u.hasUserInfo && (u.port === '' || u.port === '443') && isAppHost(u.host);
}

/** "https://host" of an app URL, or the start origin. */
export function appOriginOf(raw: string | null | undefined): string {
  if (raw && isAppUrl(raw)) {
    const u = parseUrl(raw)!;
    return `https://${u.host}`;
  }
  return START_ORIGIN;
}
