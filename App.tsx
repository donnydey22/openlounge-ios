import { phoneAuthConfirm, phoneAuthStart } from './src/phoneAuth';
import * as Network from 'expo-network';
import * as Notifications from 'expo-notifications';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import * as SystemUI from 'expo-system-ui';
import * as WebBrowser from 'expo-web-browser';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, type AppStateStatus, Keyboard, Linking, Platform, Share, StyleSheet, View } from 'react-native';
import { SafeAreaProvider, initialWindowMetrics, useSafeAreaInsets } from 'react-native-safe-area-context';
import { WebView, type WebViewMessageEvent, type WebViewNavigation } from 'react-native-webview';
import type { ShouldStartLoadRequest } from 'react-native-webview/lib/WebViewTypes';

import { LaunchOverlay } from './src/LaunchOverlay';
import { LockScreen } from './src/LockScreen';
import { IncomingCallCard } from './src/IncomingCallCard';
import * as BioLock from './src/biometricLock';
import { isCallAcceptPath, shouldReportVisible } from './src/lockPolicy';
import { OfflineScreen } from './src/OfflineScreen';
import {
  audioResumeScript,
  injectedBeforeContentLoaded,
  keyboardScript,
  nativeEventScript,
  parseBridgeMessage,
  resolveScript,
} from './src/bridge';
import {
  APP_SCHEME,
  APP_VERSION,
  APP_BUILD,
  AUTH_CALLBACK,
  COLORS,
  EDGE_TO_EDGE_TOP,
  KEYBOARD_MODE,
  SPLASH_MAX_MS,
  START_URL,
  isAppUrl,
} from './src/config';
import { playHaptic } from './src/haptics';
import { readContactsForPage } from './src/contacts';
import { initPush, onForegroundPush, onNotificationOpen, onTokenRefresh, requestPushPermissionAndToken } from './src/push';
import type { ForegroundPushData } from './src/pushPayload';
import { ForegroundPushQueue } from './src/foregroundPushQueue';
import { type LinkTarget, isNativeAuthStart, resolveIncomingLink } from './src/links';
import * as Session from './src/sessionStore';
import {
  type CallAction,
  acceptUrl,
  accessFromSession,
  forwardPageCallMessage,
  nativeCallsAvailable,
  postVoipToken,
  startNativeCalls,
  syncCallAuthFromSession,
} from './src/calls';
import { type Theme, loadTheme, saveTheme } from './src/themeStore';
import { schemeOf } from './src/url';

// Keep the native splash (same artwork/colours as Android's launch screen) up until the page has painted and the
// web app finished its session check (OpenLoungeNative.ready() or the automatic AuthGate check in bridge.ts).
try {
  SplashScreen.preventAutoHideAsync().catch(() => {});
  SplashScreen.setOptions({ fade: false, duration: 0 }); // LaunchOverlay takes over seamlessly (same bg)
} catch {}

const themeColor = (t: Theme) => (t === 'light' ? COLORS.light : COLORS.dark);

// WebKit errors that are not "the page could not be loaded".
const IGNORED_LOAD_ERRORS = new Set([
  -999, // NSURLErrorCancelled: superseded navigation
  102, // WebKitErrorFrameLoadInterruptedByPolicyChange: we cancelled it in onShouldStartLoadWithRequest
  204, // WebKitErrorPlugInWillHandleLoad (media documents)
]);

function openInSafariView(url: string) {
  const s = schemeOf(url);
  if (s !== 'http' && s !== 'https') {
    Linking.openURL(url).catch(() => {});
    return;
  }
  WebBrowser.openBrowserAsync(url, {
    controlsColor: COLORS.accent,
    dismissButtonStyle: 'done',
    enableBarCollapsing: true,
  }).catch(() => {
    // another SFSafariViewController is already up, or the URL is unsupported → hand it to iOS
    Linking.openURL(url).catch(() => {});
  });
}

function Shell() {
  const insets = useSafeAreaInsets();
  const webRef = useRef<WebView>(null);
  const [launchReady, setLaunchReady] = useState(false);
  const [theme, setThemeState] = useState<Theme>('dark'); // the web app defaults to dark
  const [offline, setOffline] = useState(false);
  const [webKey, setWebKey] = useState(0);
  const [sourceUri, setSourceUri] = useState(START_URL);
  const [kbHeight, setKbHeight] = useState(0);

  const injected = useMemo(() => injectedBeforeContentLoaded(Platform.OS, APP_VERSION, nativeCallsAvailable(), APP_BUILD), []);

  // ---- refs read from long-lived listeners ----
  const offlineRef = useRef(false);
  const everLoaded = useRef(false); // this WebView instance finished a successful main-frame load
  const navFailed = useRef(false);
  const currentUrl = useRef<string>(START_URL);
  const splashHidden = useRef(false);
  const retryAttempt = useRef(0);
  const retryTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const authBusy = useRef(false);
  const handledCodes = useRef(new Set<string>());
  const appState = useRef<AppStateStatus>(AppState.currentState);
  // Retain separate notifications during a brief WebView/lifecycle race. A new event for an existing collapse tag
  // replaces the older one, matching FCM's per-thread/per-room collapse behavior without dropping other activity.
  const pendingForegroundPushes = useRef(new ForegroundPushQueue());

  const inject = useCallback((js: string) => webRef.current?.injectJavaScript(js), []);
  const forwardForegroundPush = useCallback((data: ForegroundPushData) => {
    // A push can win a foreground/background race while WebKit is loading or transitionally inactive. Retain every
    // distinct collapse tag until the app has a visible page instead of silently losing its reconciliation update.
    if (!everLoaded.current || appState.current !== 'active') {
      pendingForegroundPushes.current.enqueue(data);
      return;
    }
    inject(nativeEventScript('openlounge:native-notification', data));
  }, [inject]);
  const flushForegroundPush = useCallback(() => {
    if (!everLoaded.current || appState.current !== 'active') return;
    const queued = pendingForegroundPushes.current.drain();
    if (!queued.length) return;
    for (const data of queued) inject(nativeEventScript('openlounge:native-notification', data));
  }, [inject]);

  // ---------------- opt-in biometric app lock (src/biometricLock.ts) ----------------
  // 'checking' (cold start, until the stored setting is read) and 'locked' both cover the WebView.
  const [lock, setLock] = useState<'checking' | 'locked' | 'unlocked'>('checking');
  const [lockActions, setLockActions] = useState(false);
  const [lockFailed, setLockFailed] = useState(false);
  const [privacy, setPrivacy] = useState(false); // app switcher snapshot cover while the lock is on
  const lockEnabled = useRef(false);
  const lockRef = useRef(lock);
  lockRef.current = lock;
  const prompting = useRef(false);
  const backgroundedAt = useRef(0);
  const [incomingCard, setIncomingCard] = useState<{ callId: string; name: string; video: boolean } | null>(null);

  const unlockForCall = useCallback(() => {
    setLock('unlocked');
    setPrivacy(false);
    setLockActions(false);
    setLockFailed(false);
  }, []);

  // Keep the page's presence:visible in sync with App Lock (server sends CallKit/FCM only when not-visible).
  const reportLockAndVisibility = useCallback(
    (nextLock: 'checking' | 'locked' | 'unlocked', appActive: boolean) => {
      const visible = shouldReportVisible(appActive, nextLock);
      inject(nativeEventScript('openlounge:native-lock', { locked: nextLock !== 'unlocked' }));
      inject(nativeEventScript('openlounge:native-visibility', { visible }));
    },
    [inject],
  );


  const promptUnlock = useCallback(async (otherWay: boolean) => {
    if (prompting.current) return;
    prompting.current = true;
    setLockActions(false);
    // LocalAuthentication with device fallback: Face ID / Touch ID, "Use Passcode" in the sheet; "Use another
    // way" re-opens it with a passcode-first message (iOS offers the passcode after a biometric miss).
    const status = await BioLock.authenticate(otherWay ? 'Enter your iPhone passcode to unlock' : 'Unlock Open Lounge');
    prompting.current = false;
    if (status === 'success') {
      setLock('unlocked');
      setLockFailed(false);
    } else if (status === 'unavailable' && !(await BioLock.isAvailable())) {
      // passcode removed: never lock the user out of their own app
      await BioLock.setEnabledFlag(false).catch(() => {});
      lockEnabled.current = false;
      setLock('unlocked');
    } else {
      setLockFailed(status === 'failed');
      setLockActions(true);
    }
  }, []);

  useEffect(() => {
    BioLock.getEnabled().then((on) => {
      lockEnabled.current = on;
      if (BioLock.shouldLock(on, 0, Date.now())) {
        setLock('locked');
        promptUnlock(false);
      } else setLock('unlocked');
    });
  }, [promptUnlock]);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      if (prompting.current) return; // the Face ID / passcode sheet itself makes the app 'inactive'
      if (next === 'background') backgroundedAt.current = Date.now();
      if (next !== 'active') {
        if (lockEnabled.current) setPrivacy(true);
        reportLockAndVisibility(lockRef.current, false);
        return;
      }
      setPrivacy(false);
      const since = backgroundedAt.current;
      backgroundedAt.current = 0;
      if (since > 0 && lockRef.current === 'unlocked' && BioLock.shouldLock(lockEnabled.current, since, Date.now())) {
        setLock('locked');
        promptUnlock(false);
        reportLockAndVisibility('locked', true);
      } else {
        reportLockAndVisibility(lockRef.current, true);
      }
    });
    return () => sub.remove();
  }, [promptUnlock, reportLockAndVisibility]);

  useEffect(() => {
    reportLockAndVisibility(lock, appState.current === 'active');
  }, [lock, reportLockAndVisibility]);

  // ---------------- splash ----------------
  const hideSplash = useCallback(() => {
    if (splashHidden.current) return;
    splashHidden.current = true;
    setLaunchReady(true); // fades the wordmark overlay out; the native splash was already handed to it
  }, []);

  useEffect(() => {
    const t = setTimeout(hideSplash, SPLASH_MAX_MS);
    return () => clearTimeout(t);
  }, [hideSplash]);

  // ---------------- theme ----------------
  const themeFromWeb = useRef(false);
  const applyTheme = useCallback((t: Theme, fromWeb: boolean) => {
    if (fromWeb) themeFromWeb.current = true;
    else if (themeFromWeb.current) return; // the page already reported its (newer) theme
    setThemeState(t);
    try {
      SystemUI.setBackgroundColorAsync(themeColor(t)).catch(() => {});
    } catch {}
    if (fromWeb) saveTheme(t);
  }, []);

  useEffect(() => {
    let alive = true;
    loadTheme().then((t) => {
      if (alive && t) applyTheme(t, false);
    });
    return () => {
      alive = false;
    };
  }, [applyTheme]);

  // ---------------- offline / retry ----------------
  const setOfflineBoth = useCallback((v: boolean) => {
    offlineRef.current = v;
    setOffline(v);
  }, []);

  const clearRetry = () => {
    if (retryTimer.current) clearTimeout(retryTimer.current);
    retryTimer.current = null;
  };

  const lastRetryAt = useRef(0);
  const retryNow = useCallback(() => {
    clearRetry();
    lastRetryAt.current = Date.now();
    navFailed.current = false;
    if (everLoaded.current && webRef.current) webRef.current.reload();
    else setWebKey((k) => k + 1); // a never-loaded WKWebView has nothing to reload
  }, []);

  const scheduleRetry = useCallback(() => {
    clearRetry();
    const delay = Math.min(30_000, 2_000 * 2 ** Math.min(retryAttempt.current, 4));
    retryAttempt.current += 1;
    retryTimer.current = setTimeout(retryNow, delay);
  }, [retryNow]);

  const goOffline = useCallback(() => {
    navFailed.current = true;
    setOfflineBoth(true);
    scheduleRetry();
    hideSplash();
  }, [hideSplash, scheduleRetry, setOfflineBoth]);

  // Network comes back → retry immediately (NWPathMonitor via expo-network).
  useEffect(() => {
    let sub: { remove: () => void } = { remove: () => {} };
    try {
    sub = Network.addNetworkStateListener((s) => {
      // Wi-Fi ⇄ cellular handoff → the page restarts ICE in place (native-only call adaptation, netAdapt.ts)
      if (s.isConnected !== false && s.type) {
        webRef.current?.injectJavaScript(`try{window.__olNetworkChanged&&window.__olNetworkChanged(${JSON.stringify(String(s.type).toLowerCase())})}catch(e){};true;`);
      }
      if (!offlineRef.current || s.isConnected === false || s.isInternetReachable === false) return;
      if (Date.now() - lastRetryAt.current < 1500) return; // path updates arrive in bursts
      retryNow();
    });
    } catch {}
    return () => sub.remove();
  }, [retryNow]);

  useEffect(() => () => clearRetry(), []);

  // ---------------- navigation helpers ----------------
  const navigate = useCallback((url: string) => {
    if (!isAppUrl(url)) return;
    if (everLoaded.current && !offlineRef.current && webRef.current) {
      webRef.current.injectJavaScript(`location.assign(${JSON.stringify(url)});true;`);
    } else {
      currentUrl.current = url;
      everLoaded.current = false; // fresh WebView instance
      setSourceUri(url);
      setWebKey((k) => k + 1);
    }
  }, []);

  const openTarget = useCallback(
    (t: LinkTarget | null) => {
      if (!t) return;
      if (t.code) {
        if (handledCodes.current.has(t.code)) return; // same code via auth session + Linking
        handledCodes.current.add(t.code);
      }
      navigate(t.url);
    },
    [navigate],
  );

  const handleIncomingUrl = useCallback(
    (url: string | null) => {
    if (url && isCallAcceptPath(url)) unlockForCall();
      if (url) openTarget(resolveIncomingLink(url, currentUrl.current));
    },
    [openTarget, unlockForCall],
  );

  // Google / Apple: ASWebAuthenticationSession, callback openlounge://auth?code=… → /auth/complete in the WebView.
  const runAuth = useCallback(
    async (startUrl: string) => {
      if (authBusy.current) return;
      authBusy.current = true;
      try {
        const res = await WebBrowser.openAuthSessionAsync(startUrl, AUTH_CALLBACK, { preferEphemeralSession: false });
        if (res.type === 'success' && res.url) openTarget(resolveIncomingLink(res.url, startUrl));
        // 'cancel' / 'dismiss': the user closed the sheet; the sign-in screen is still there.
      } catch {
        // ASWebAuthenticationSession could not start; the page's own error handling covers it.
      } finally {
        authBusy.current = false;
      }
    },
    [openTarget],
  );

  // ---------------- push ----------------
  const pushToken = useRef('');
  const deliverPushToken = useCallback(
    (t: string) => {
      if (!t) return;
      pushToken.current = t;
      const q = JSON.stringify(t);
      inject(`window.__olExpoPushToken=${q};window.__olPushToken&&window.__olPushToken(${q});true;`);
    },
    [inject],
  );
  // Push is initialised only after the WebView's first load finished (+1.5 s), never at launch, and any failure
  // just leaves push off (see src/push.ts).
  const [pushReady, setPushReady] = useState(false);
  const pushTimerSet = useRef(false);
  const schedulePushInit = useCallback(() => {
    if (pushTimerSet.current) return;
    pushTimerSet.current = true;
    setTimeout(() => {
      try {
        setPushReady(initPush());
      } catch (e) {
        console.warn('[push] init failed (ignored):', e);
      }
    }, 1500);
  }, []);
  useEffect(() => {
    if (!pushReady) return;
    let offRefresh = () => {};
    let offOpen = () => {};
    let offForeground = () => {};
    try {
      offRefresh = onTokenRefresh(deliverPushToken);
      offForeground = onForegroundPush(forwardForegroundPush);
      // notification tap → open its deep link (/messages/<peer>, /room/<id>) in the WebView
      offOpen = onNotificationOpen((path) => {
        try {
          navigate(new URL(path, START_URL).toString());
        } catch {}
      });
    } catch (e) {
      console.warn('[push] listeners failed (ignored):', e);
    }
    return () => {
      offRefresh();
      offOpen();
      offForeground();
    };
  }, [pushReady, deliverPushToken, forwardForegroundPush, navigate]);

  // ---------------- native call ringing (CallKit/PushKit, src/calls.ts) ----------------
  const access = useRef<{ access: string; exp: number } | null>(null);
  const voipToken = useRef('');
  const voipSent = useRef({ key: '', at: 0 });
  const appOrigin = () => {
    try {
      return new URL(isAppUrl(currentUrl.current) ? currentUrl.current : START_URL).origin;
    } catch {
      return START_URL;
    }
  };
  // Register the PushKit token whenever both it and a fresh access token are known (sign-in, token rotation,
  // new PushKit token); at most every 6 h for the same token+account.
  const syncVoip = useCallback(() => {
    const t = voipToken.current;
    const a = access.current;
    if (!t || !a || a.exp < Date.now() + 10_000) return;
    const key = `${t}:${a.access.slice(0, 24)}`;
    if (voipSent.current.key === key && Date.now() - voipSent.current.at < 6 * 3600_000) return;
    voipSent.current = { key, at: Date.now() };
    void postVoipToken(appOrigin(), t, a.access).then((st) => {
      if (st < 200 || st >= 300) voipSent.current = { key: '', at: 0 }; // retry on the next rotation
    });
  }, []);
  const onSessionChanged = useCallback(
    (json: string | null) => {
      syncCallAuthFromSession(json);
      access.current = accessFromSession(json);
      syncVoip();
    },
    [syncVoip],
  );
  const onCallAction = useCallback(
    (a: CallAction, coldStart: boolean) => {
      if ((a as { type: string }).type === 'ringback') {
        // native ringback status → page (0.3.13+): the web ring takes over if native is not actually playing
        const playing = !!(a as unknown as { playing?: boolean }).playing;
        if (!coldStart && everLoaded.current)
          inject(`(function(){try{window.dispatchEvent(new CustomEvent('openlounge:native-ringback',{detail:{playing:${playing}}}))}catch(e){}})();true;`);
        return;
      }
      if ((a as { type: string }).type === 'audioRoute') {
        const r = a as unknown as { headset?: boolean; port?: string; name?: string; reason?: number };
        const detail = JSON.stringify({ headset: !!r.headset, port: String(r.port || ''), name: String(r.name || ''), reason: Number(r.reason || 0) });
        if (!coldStart && everLoaded.current)
          inject(`(function(){try{window.dispatchEvent(new CustomEvent('openlounge:native-audio-route',{detail:${detail}}))}catch(e){}})();true;`);
        return;
      }
      if (a.type === 'audio') {
        if (!coldStart && everLoaded.current) inject(audioResumeScript(a.reason));
        return;
      }
      if (a.type === 'answer') {
        unlockForCall();
        setIncomingCard(null);
        const url = acceptUrl(appOrigin(), a.callId);
        // Page already loaded (push-woken ring): accept in place — no reload, keeps the warm socket/session (~7 s
        // faster accept→audio). The page falls back to the /call/<id>?accept=1 navigation itself if it can't.
        if (!coldStart && everLoaded.current) {
          inject(`(function(){try{if(window.__olAcceptCall&&window.__olAcceptCall(${JSON.stringify(a.callId)}))return;}catch(e){}location.assign(${JSON.stringify(url)});})();true;`);
        } else navigate(url); // /call/<id>?accept=1: the web layer joins instantly
        return;
      }
      if (a.type === 'decline' || a.type === 'hangup') setIncomingCard(null);
      if (coldStart || !everLoaded.current) return; // nothing to tell a page that isn't loaded
      const detail = a.type === 'mute' ? { type: 'call:mute', muted: a.muted } : { type: a.type === 'decline' ? 'call:decline' : 'call:hangup' };
      inject(nativeEventScript('openlounge:native-call', detail));
    },
    [navigate, inject, unlockForCall],
  );
  useEffect(() => {
    if (!nativeCallsAvailable()) return;
    Session.getSession()
      .then((json) => onSessionChanged(json))
      .catch(() => {});
    const { pending, stop } = startNativeCalls(
      (a) => onCallAction(a, false),
      (t) => {
        voipToken.current = t;
        syncVoip();
      },
    );
    for (const a of pending) onCallAction(a, true);
    return stop;
  }, [onCallAction, onSessionChanged, syncVoip]);

  // Deep links: cold start + while running.
  useEffect(() => {
    Linking.getInitialURL()
      .then(handleIncomingUrl)
      .catch(() => {});
    const sub = Linking.addEventListener('url', (e) => handleIncomingUrl(e.url));
    return () => sub.remove();
  }, [handleIncomingUrl]);

  // ---------------- app lifecycle: visibility + audio recovery ----------------
  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      const prev = appState.current;
      appState.current = next;
      if (next === 'background') {
        inject(nativeEventScript('openlounge:native-visibility', { visible: false }));
      } else if (next === 'active' && prev !== 'active') {
        // Only report visible when App Lock is not covering the WebView.
        inject(nativeEventScript('openlounge:native-visibility', { visible: shouldReportVisible(true, lockRef.current) }));
        flushForegroundPush();
        inject(audioResumeScript(prev === 'background' ? 'foreground' : 'interruption'));
        if (offlineRef.current) retryNow();
      }
    });
    return () => sub.remove();
  }, [flushForegroundPush, inject, retryNow]);

  // ---------------- keyboard ----------------
  useEffect(() => {
    const show = Keyboard.addListener('keyboardWillShow', (e) => {
      const h = e.endCoordinates.height;
      inject(keyboardScript(true, h, e.duration ?? 250));
      if (KEYBOARD_MODE === 'resize') setKbHeight(h);
    });
    const hide = Keyboard.addListener('keyboardWillHide', (e) => {
      inject(keyboardScript(false, 0, e.duration ?? 250));
      if (KEYBOARD_MODE === 'resize') setKbHeight(0);
    });
    return () => {
      show.remove();
      hide.remove();
    };
  }, [inject]);

  // ---------------- bridge ----------------
  const reply = useCallback(
    (id: string, ok: boolean, result?: unknown, err?: string) => inject(resolveScript(id, ok, result, err)),
    [inject],
  );

  const onMessage = useCallback(
    async (e: WebViewMessageEvent) => {
      // Only the Open Lounge origin may use the native bridge (frame URL, strict parser).
      if (!isAppUrl(e.nativeEvent.url)) return;
      const msg = parseBridgeMessage(e.nativeEvent.data);
      if (!msg) return;
      switch (msg.method) {
        case 'theme':
          applyTheme(msg.value, true);
          return;
        case 'ready':
          hideSplash();
          return;
        case 'haptic':
          playHaptic(msg.value);
          return;
        case 'openExternal':
          if (isAppUrl(msg.value)) navigate(msg.value);
          else openInSafariView(msg.value);
          return;
        case 'share':
          Share.share({ message: msg.value.text, url: msg.value.url }).catch(() => {});
          return;
        case 'requestContacts':
          readContactsForPage()
            .catch(() => JSON.stringify({ granted: false }))
            .then((json) => inject(`window.__olContacts&&window.__olContacts(${JSON.stringify(json)});true;`));
          return;
        case 'openAppSettings':
          Linking.openSettings().catch(() => {});
          return;
        case 'setBadge':
          // app-icon badge = total unread reported by the web app (0 clears)
          void Notifications.setBadgeCountAsync(msg.value).catch(() => {});
          return;
        case 'requestNotificationPermission':
          // the page calls this after sign-in; iOS shows its prompt once
          requestPushPermissionAndToken()
            .then((t) => {
              setPushReady(true);
              deliverPushToken(t);
            })
            .catch(() => {});
          return;
        case 'call': {
          const v = msg.value as { type?: string; callId?: string; name?: string; video?: boolean };
          forwardPageCallMessage(msg.value);
          if (v?.type === 'call:incoming' && typeof v.callId === 'string' && lockRef.current !== 'unlocked') {
            // Fallback card above LockScreen if CallKit is delayed / refused; CallKit still gets the page message.
            setIncomingCard({ callId: v.callId, name: typeof v.name === 'string' ? v.name : 'Incoming call', video: v.video === true });
          } else if (v?.type === 'call:ended' || v?.type === 'call:connected') {
            setIncomingCard(null);
            if (v?.type === 'call:connected') unlockForCall();
          }
          return;
        }
        case 'phoneAuthStart':
        case 'phoneAuthConfirm': {
          const v = msg.value;
          const run = msg.method === 'phoneAuthStart' ? phoneAuthStart(v.id, (v as { phone: string }).phone) : phoneAuthConfirm(v.id, (v as { code: string }).code);
          run.then((r) => inject(`window.__olPhoneAuth&&window.__olPhoneAuth(${JSON.stringify(JSON.stringify(r))});true;`));
          return;
        }
        case 'openAuth':
          if (!isNativeAuthStart(msg.value)) {
            reply(msg.id, false, null, 'openAuth: unsupported URL');
            return;
          }
          reply(msg.id, true, null); // the system sheet takes over; the result comes back as a navigation
          runAuth(msg.value);
          return;
      }
      try {
        if (msg.method === 'bioIsAvailable') return void reply(msg.id, true, await BioLock.isAvailable());
        if (msg.method === 'bioGetEnabled') return void reply(msg.id, true, await BioLock.getEnabled());
        if (msg.method === 'bioSetEnabled') {
          prompting.current = true;
          let on = false;
          try {
            on = await BioLock.setEnabled(msg.value);
          } finally {
            prompting.current = false;
          }
          lockEnabled.current = on;
          return void reply(msg.id, true, on);
        }
        if (msg.method === 'getSession') reply(msg.id, true, await Session.getSession());
        else if (msg.method === 'setSession') {
          reply(msg.id, true, await Session.setSession(msg.value));
          onSessionChanged(msg.value);
        } else if (msg.method === 'clearSession') {
          // sign-out: unregister this phone's PushKit token while the access token is still valid
          const a = access.current;
          if (voipToken.current && a && a.exp > Date.now() + 5_000) void postVoipToken(appOrigin(), voipToken.current, a.access, true);
          voipSent.current = { key: '', at: 0 };
          reply(msg.id, true, await Session.clearSession());
          onSessionChanged(null);
        }
      } catch (err) {
        reply(msg.id, false, null, err instanceof Error ? err.message : String(err));
      }
    },
    [applyTheme, hideSplash, navigate, reply, runAuth, inject, deliverPushToken, onSessionChanged],
  );

  // ---------------- link policy ----------------
  const onShouldStartLoadWithRequest = useCallback(
    (req: ShouldStartLoadRequest) => {
      const { url } = req;
      const scheme = schemeOf(url);
      if (scheme === 'about' || scheme === 'blob' || scheme === 'data') return true;
      if (scheme === APP_SCHEME) {
        handleIncomingUrl(url);
        return false;
      }
      if (scheme === 'http' || scheme === 'https') {
        if (isAppUrl(url)) {
          if (req.isTopFrame !== false && isNativeAuthStart(url)) {
            runAuth(url); // Google/Apple refuse embedded WebViews
            return false;
          }
          return true;
        }
        // Sub-frames (embeds) may load anything; a top-level page on another site opens in SFSafariViewController.
        if (req.isTopFrame === false) return true;
        openInSafariView(url);
        return false;
      }
      // mailto:, tel:, sms:, itms-apps:, … → hand off to iOS.
      Linking.openURL(url).catch(() => {});
      return false;
    },
    [handleIncomingUrl, runAuth],
  );

  const onNavChange = useCallback((nav: WebViewNavigation) => {
    if (isAppUrl(nav.url)) currentUrl.current = nav.url;
  }, []);

  const bg = themeColor(theme);

  return (
    <View style={[styles.root, { backgroundColor: bg }]}>
      <StatusBar style={theme === 'light' ? 'dark' : 'light'} animated />
      <View
        style={[
          styles.root,
          { paddingTop: EDGE_TO_EDGE_TOP ? 0 : insets.top, paddingBottom: KEYBOARD_MODE === 'resize' ? kbHeight : 0 },
        ]}
      >
        <WebView
          key={webKey}
          ref={webRef}
          source={{ uri: sourceUri, headers: { 'Cache-Control': 'no-cache' } }}
          style={[styles.root, { backgroundColor: bg }]}
          containerStyle={{ backgroundColor: bg }}
          // Safe areas: no automatic insets; the page sees real env(safe-area-inset-*) values (bottom: home
          // indicator; top is 0 because the WebView starts below the status bar unless EDGE_TO_EDGE_TOP).
          contentInsetAdjustmentBehavior="never"
          automaticallyAdjustContentInsets={false}
          automaticallyAdjustsScrollIndicatorInsets={false}
          // Bridge
          injectedJavaScriptBeforeContentLoaded={injected}
          injectedJavaScriptForMainFrameOnly
          injectedJavaScriptBeforeContentLoadedForMainFrameOnly
          onMessage={onMessage}
          // Audio rooms (LiveKit/WebRTC): WebKit itself runs AVAudioSession as playAndRecord with
          // defaultToSpeaker + Bluetooth (HFP/A2DP) + AirPlay while the mic is captured. Grant getUserMedia for
          // the page's own host only (openlounge.app), deny cross-origin frames, so WebKit never re-prompts.
          mediaCapturePermissionGrantType="grantIfSameHostElseDeny"
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          allowsAirPlayForMediaPlayback
          allowsPictureInPictureMediaPlayback={false}
          // Persistent cookies/localStorage (default data store)
          sharedCookiesEnabled
          domStorageEnabled
          javaScriptEnabled
          javaScriptCanOpenWindowsAutomatically
          setSupportMultipleWindows={false}
          // Feel
          allowsBackForwardNavigationGestures // edge swipe = web history back/forward
          allowsLinkPreview={false}
          bounces={false}
          overScrollMode="never"
          pullToRefreshEnabled={false}
          dataDetectorTypes="none"
          textInteractionEnabled
          keyboardDisplayRequiresUserAction={false}
          hideKeyboardAccessoryView
          decelerationRate="normal"
          applicationNameForUserAgent={`OpenLounge/ios/${APP_VERSION}(${APP_BUILD}) OpenLoungeiOS/${APP_VERSION} OpenLoungeExpo/${APP_VERSION}`}
          webviewDebuggingEnabled={__DEV__}
          originWhitelist={['https://*', 'http://*', 'about:*', 'blob:*', 'data:*', `${APP_SCHEME}:*`]}
          onShouldStartLoadWithRequest={onShouldStartLoadWithRequest}
          onOpenWindow={(e) => {
            const url = e.nativeEvent.targetUrl;
            if (isAppUrl(url)) navigate(url);
            else if (schemeOf(url) === APP_SCHEME) handleIncomingUrl(url);
            else openInSafariView(url);
          }}
          onNavigationStateChange={onNavChange}
          onLoadStart={() => {
            navFailed.current = false;
          }}
          onLoadEnd={() => {
            if (navFailed.current) return;
            everLoaded.current = true;
            flushForegroundPush();
            retryAttempt.current = 0;
            clearRetry();
            if (offlineRef.current) setOfflineBoth(false);
            hideSplash(); // first page loaded → reveal (LaunchOverlay also self-caps at 1.5s)
            schedulePushInit();
          }}
          onError={(e) => {
            if (IGNORED_LOAD_ERRORS.has(e.nativeEvent.code)) return;
            goOffline(); // calm offline screen + quiet automatic retry, never a dialog or raw error text
          }}
          onHttpError={(e) => {
            if (e.nativeEvent.statusCode >= 500 && isAppUrl(e.nativeEvent.url)) goOffline();
          }}
          onContentProcessDidTerminate={() => webRef.current?.reload()}
          startInLoadingState={false}
        />
      </View>

      <LaunchOverlay ready={launchReady} theme={theme} onShown={() => SplashScreen.hideAsync().catch(() => {})} />
      {offline && <OfflineScreen theme={theme} onRetryNow={retryNow} insets={insets} />}
      {(lock !== 'unlocked' || privacy) && (
        <LockScreen
          showActions={lock === 'locked' && lockActions}
          failed={lockFailed}
          onRetry={() => promptUnlock(false)}
          onOtherWay={() => promptUnlock(true)}
        />
      )}
      {incomingCard && (
        <IncomingCallCard
          name={incomingCard.name}
          video={incomingCard.video}
          onAccept={() => {
            const id = incomingCard.callId;
            unlockForCall();
            setIncomingCard(null);
            navigate(acceptUrl(appOrigin(), id));
          }}
          onDecline={() => {
            inject(nativeEventScript('openlounge:native-call', { type: 'call:decline' }));
            setIncomingCard(null);
          }}
        />
      )}
    </View>
  );
}

export default function App() {
  return (
    <SafeAreaProvider initialMetrics={initialWindowMetrics} style={{ backgroundColor: COLORS.dark }}>
      <Shell />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
});
