// Native bridge for the Open Lounge web app inside the iOS (Expo) wrapper.
// Superset of the Android wrapper's session store (src/lib/session.ts in the web repo):
//
//   window.OpenLoungeNative = {
//     getSession():              Promise<string | null>     Keychain-backed durable session store
//     setSession(json: string):  Promise<void>
//     clearSession():            Promise<void>
//     ready():                   void   page painted / session check done → native splash fades out
//     haptic(kind: string):      void   'raiseHand' | 'joinStage' | 'sendDm' | 'light' | 'medium' | 'heavy'
//                                       | 'soft' | 'rigid' | 'selection' | 'success' | 'warning' | 'error'
//     openAuth(url: string):     Promise<void>   Google/Apple start URL → ASWebAuthenticationSession
//     openExternal(url: string): void   https URL → SFSafariViewController
//     haptics(type: string):     void   0.3.0 cross-platform contract (/workspace/native/HAPTICS_BRIDGE.md):
//                                       'light' | 'medium' | 'heavy' | 'success' | 'warning' | 'error' | 'selection'
//     openBrowser(url: string):  void   0.3.0 cross-platform contract (/workspace/native/BROWSER_BRIDGE.md):
//                                       external https → SFSafariViewController; openlounge.app → stays in the app
//     biometrics: { isAvailable(): Promise<boolean>, getEnabled(): Promise<boolean>,
//                   setEnabled(on: boolean): Promise<boolean> }   opt-in app lock; setEnabled(true) prompts first
//     __expo: true, platform: 'ios', version: '0.2.3', capabilities: string[]
//   }
//
// Feature-detect optional methods (the Android wrapper only has the three session methods):
//   window.OpenLoungeNative?.haptic?.('raiseHand')
//
// Transport: injectedJavaScriptBeforeContentLoaded defines the (frozen) object before any page script runs.
// Calls that return a value post {"__ol":1,"id":"<request id>","method":…,"value"?:string} through
// window.ReactNativeWebView.postMessage; the app answers with window.__openLoungeNativeResolve(id, ok, result, error)
// via injectJavaScript (10 s timeout → reject). Fire-and-forget calls post {"__ol":1,"method":…,"value"?:…}.
// Only pages on the app's own https hosts get answers / have their messages honoured.
//
// Events the app dispatches on window (CustomEvent, detail shown):
//   openlounge:native-visibility    {visible: boolean}            app foreground/background (same as Android)
//   openlounge:native-audio-resume  {reason: string, kicked: n}   after a phone call / Siri / backgrounding the app
//                                                                 resumed suspended AudioContexts and paused
//                                                                 MediaStream <audio>; LiveKit pages can also call
//                                                                 room.startAudio() here
//   openlounge:native-keyboard      {visible, height, duration}   keyboard frame (also CSS var --ol-keyboard-height)
// Automatic page → app message: {"__ol":1,"method":"theme","value":"dark"|"light"} from <html data-theme>.

export type HapticKind =
  | 'raiseHand'
  | 'joinStage'
  | 'sendDm'
  | 'light'
  | 'medium'
  | 'heavy'
  | 'soft'
  | 'rigid'
  | 'selection'
  | 'success'
  | 'warning'
  | 'error';

const HAPTICS = new Set<string>([
  'raiseHand',
  'joinStage',
  'sendDm',
  'light',
  'medium',
  'heavy',
  'soft',
  'rigid',
  'selection',
  'success',
  'warning',
  'error',
]);

export type BridgeRequest =
  | { __ol: 1; id: string; method: 'getSession' }
  | { __ol: 1; id: string; method: 'setSession'; value: string }
  | { __ol: 1; id: string; method: 'clearSession' }
  | { __ol: 1; id: string; method: 'openAuth'; value: string }
  | { __ol: 1; id: string; method: 'bioIsAvailable' }
  | { __ol: 1; id: string; method: 'bioGetEnabled' }
  | { __ol: 1; id: string; method: 'bioSetEnabled'; value: boolean }
  | { __ol: 1; method: 'theme'; value: 'dark' | 'light' }
  | { __ol: 1; method: 'ready'; value?: string }
  | { __ol: 1; method: 'haptic'; value: HapticKind }
  | { __ol: 1; method: 'openExternal'; value: string }
  | { __ol: 1; method: 'share'; value: { text: string; url: string } }
  | { __ol: 1; method: 'requestContacts' }
  | { __ol: 1; method: 'openAppSettings' }
  | { __ol: 1; method: 'requestNotificationPermission' }
  | { __ol: 1; method: 'setBadge'; value: number }
  | { __ol: 1; method: 'phoneAuthStart'; value: { id: string; phone: string } }
  | { __ol: 1; method: 'phoneAuthConfirm'; value: { id: string; code: string } }
  | { __ol: 1; method: 'call'; value: PageCallMessage }
  /** native call media (src/nativeMedia.ts): page → app command, answered via resolveScript */
  | { __ol: 1; id: string; method: 'nativeMedia'; value: Record<string, unknown> }
  /** page's answer to an app-originated ms:* signaling request (window.__olNativeMsReq) */
  | { __ol: 1; method: 'msReply'; value: { id: string; ok: boolean; result: unknown; error?: string } };

/** Page → native call messages (NATIVE_SPEC.md §5), sent as plain {type:"call:*"} JSON (no __ol envelope). */
export type PageCallMessage =
  | { type: 'call:incoming'; callId: string; name: string; video: boolean; photo?: string; expiresAt?: number }
  | { type: 'call:outgoing'; callId: string; name: string; video: boolean }
  | { type: 'call:connected'; callId: string }
  | { type: 'call:ended'; callId: string }
  | { type: 'call:muted'; muted: boolean }
  | { type: 'call:audioRoute'; speaker: boolean }
  | { type: 'call:ringbackStop' };

const CALL_ID = /^[A-Za-z0-9_-]{1,64}$/;

function parseCallMessage(m: Record<string, unknown>): BridgeRequest | null {
  const id = typeof m.callId === 'string' && CALL_ID.test(m.callId) ? m.callId : '';
  const wrap = (value: PageCallMessage): BridgeRequest => ({ __ol: 1, method: 'call', value });
  switch (m.type) {
    case 'call:incoming':
      return id
        ? wrap({
            type: 'call:incoming',
            callId: id,
            name: typeof m.name === 'string' ? m.name.slice(0, 80) : '',
            video: m.video === true,
            photo: typeof m.photo === 'string' ? m.photo.slice(0, 500) : undefined,
            expiresAt: typeof m.expiresAt === 'number' ? m.expiresAt : undefined,
          })
        : null;
    case 'call:outgoing':
      return id ? wrap({ type: 'call:outgoing', callId: id, name: typeof m.name === 'string' ? m.name.slice(0, 80) : '', video: m.video === true }) : null;
    case 'call:connected':
    case 'call:ended':
      // callId may be missing on old pages; '' means "the current call"
      return typeof m.callId === 'string' && !id ? null : wrap({ type: m.type, callId: id });
    case 'call:muted':
      return typeof m.muted === 'boolean' ? wrap({ type: 'call:muted', muted: m.muted }) : null;
    case 'call:audioRoute':
      return typeof m.speaker === 'boolean' ? wrap({ type: 'call:audioRoute', speaker: m.speaker }) : null;
    case 'call:ringbackStop':
      // the page's web ringback took over (native did not confirm playing): native must stay silent
      return wrap({ type: 'call:ringbackStop' });
  }
  return null;
}

export function parseBridgeMessage(data: string): BridgeRequest | null {
  try {
    if (typeof data !== 'string' || data.length > 200_000) return null;
    const m = JSON.parse(data) as Record<string, unknown>;
    if (m && typeof m === 'object' && m.__ol === undefined && typeof m.type === 'string' && m.type.startsWith('call:')) return parseCallMessage(m);
    if (!m || m.__ol !== 1 || typeof m.method !== 'string') return null;
    switch (m.method) {
      case 'theme':
        return m.value === 'light' || m.value === 'dark' ? (m as BridgeRequest) : null;
      case 'ready':
        return { __ol: 1, method: 'ready' };
      case 'haptic':
        return typeof m.value === 'string' && HAPTICS.has(m.value) ? (m as BridgeRequest) : null;
      case 'openExternal':
        return typeof m.value === 'string' && m.value.length <= 4096 ? (m as BridgeRequest) : null;
      case 'share': {
        const v = m.value as { text?: unknown; url?: unknown } | null;
        return v && typeof v.text === 'string' && typeof v.url === 'string' && v.text.length <= 1000 && v.url.length <= 2048
          ? { __ol: 1, method: 'share', value: { text: v.text, url: v.url } }
          : null;
      }
      case 'phoneAuthStart': {
        const v = m.value as { id?: unknown; phone?: unknown } | null;
        return v && typeof v.id === 'string' && v.id.length <= 100 && typeof v.phone === 'string' && /^\+[0-9]{6,16}$/.test(v.phone)
          ? { __ol: 1, method: 'phoneAuthStart', value: { id: v.id, phone: v.phone } }
          : null;
      }
      case 'phoneAuthConfirm': {
        const v = m.value as { id?: unknown; code?: unknown } | null;
        return v && typeof v.id === 'string' && v.id.length <= 100 && typeof v.code === 'string' && /^[0-9]{4,8}$/.test(v.code)
          ? { __ol: 1, method: 'phoneAuthConfirm', value: { id: v.id, code: v.code } }
          : null;
      }
      case 'setBadge':
        return typeof m.value === 'number' && Number.isFinite(m.value) && m.value >= 0
          ? { __ol: 1, method: 'setBadge', value: Math.min(9999, Math.floor(m.value)) }
          : null;
      case 'requestContacts':
      case 'openAppSettings':
      case 'requestNotificationPermission':
        return { __ol: 1, method: m.method } as BridgeRequest;
    }
    if (m.method === 'msReply') {
      const v = m.value as { id?: unknown; ok?: unknown; result?: unknown; error?: unknown } | null;
      return v && typeof v.id === 'string' && v.id.length <= 64
        ? { __ol: 1, method: 'msReply', value: { id: v.id, ok: v.ok === true, result: v.result ?? null, error: typeof v.error === 'string' ? v.error.slice(0, 200) : undefined } }
        : null;
    }
    if (typeof m.id !== 'string' || m.id.length > 64) return null;
    if (m.method === 'nativeMedia') {
      const v = m.value as Record<string, unknown> | null;
      return v && typeof v === 'object' && typeof v.op === 'string' ? { __ol: 1, id: m.id, method: 'nativeMedia', value: v } : null;
    }
    if (m.method === 'getSession' || m.method === 'clearSession') return m as BridgeRequest;
    if (m.method === 'bioIsAvailable' || m.method === 'bioGetEnabled') return { __ol: 1, id: m.id, method: m.method } as BridgeRequest;
    if (m.method === 'bioSetEnabled' && typeof m.value === 'boolean') return { __ol: 1, id: m.id, method: 'bioSetEnabled', value: m.value };
    if ((m.method === 'setSession' || m.method === 'openAuth') && typeof m.value === 'string') return m as BridgeRequest;
    return null;
  } catch {
    return null;
  }
}

/** JS that resolves/rejects a pending request inside the page. */
export function resolveScript(id: string, ok: boolean, result: unknown, error?: string): string {
  const args = [JSON.stringify(id), ok ? 'true' : 'false', JSON.stringify(result ?? null), JSON.stringify(error ?? null)];
  return `window.__openLoungeNativeResolve&&window.__openLoungeNativeResolve(${args.join(',')});true;`;
}

/** JS that dispatches `new CustomEvent(name, {detail})` on window. */
export function nativeEventScript(name: string, detail: unknown): string {
  return `(function(){try{window.dispatchEvent(new CustomEvent(${JSON.stringify(name)},{detail:${JSON.stringify(
    detail ?? null,
  )}}));}catch(e){}})();true;`;
}

/** Keyboard frame → CSS var + event (for the chat composer). */
export function keyboardScript(visible: boolean, height: number, duration: number): string {
  const h = Math.max(0, Math.round(visible ? height : 0));
  return `(function(){try{document.documentElement.style.setProperty('--ol-keyboard-height','${h}px');}catch(e){}})();${nativeEventScript(
    'openlounge:native-keyboard',
    { visible, height: h, duration: Math.round(duration) },
  )}`;
}

/**
 * Bring audio back after an interruption (phone call, Siri, alarm) or after the app was backgrounded:
 * resume AudioContexts iOS suspended/interrupted, restart paused MediaStream <audio>/<video> elements (remote
 * LiveKit tracks), then tell the page so it can do anything LiveKit-specific (room.startAudio()).
 */
export function audioResumeScript(reason: string): string {
  return `(function(){try{
  var n=0;
  var list=window.__olAudioContexts||[];
  for(var i=0;i<list.length;i++){var c=list[i];
    if(c&&(c.state==='suspended'||c.state==='interrupted')){try{var r=c.resume();if(r&&r.catch)r.catch(function(){});n++;}catch(e){}}}
  var els=document.querySelectorAll('audio,video');
  for(var j=0;j<els.length;j++){var el=els[j];
    if(el.srcObject&&el.paused&&!el.ended&&!el.muted&&el.autoplay){try{var p=el.play();if(p&&p.catch)p.catch(function(){});n++;}catch(e){}}}
  if(window.__olRingResume){try{window.__olRingResume();n++;}catch(e){}}
  window.dispatchEvent(new CustomEvent('openlounge:native-audio-resume',{detail:{reason:${JSON.stringify(reason)},kicked:n}}));
}catch(e){}})();true;`;
}

export function injectedBeforeContentLoaded(platform: string, appVersion: string, nativeCalls = false, appBuild = ''): string {
  return `(function(){
  try {
    if (window.OpenLoungeNative && window.OpenLoungeNative.__expo) return;
    var pending = {};
    var seq = 0;
    function post(msg) {
      var bridge = window.ReactNativeWebView;
      if (!bridge || typeof bridge.postMessage !== 'function') return false;
      try { bridge.postMessage(JSON.stringify(msg)); return true; } catch (e) { return false; }
    }
    function call(method, value, timeoutMs) {
      return new Promise(function (resolve, reject) {
        var bridge = window.ReactNativeWebView;
        if (!bridge || typeof bridge.postMessage !== 'function') { reject(new Error('OpenLoungeNative unavailable')); return; }
        var id = 'ol' + Date.now().toString(36) + '_' + (++seq);
        var timer = setTimeout(function () {
          if (pending[id]) { delete pending[id]; reject(new Error('OpenLoungeNative ' + method + ' timed out')); }
        }, timeoutMs || 10000);
        pending[id] = { resolve: resolve, reject: reject, timer: timer };
        var msg = { __ol: 1, id: id, method: method };
        if (value !== undefined) msg.value = value;
        try { bridge.postMessage(JSON.stringify(msg)); }
        catch (e) { clearTimeout(timer); delete pending[id]; reject(e); }
      });
    }
    function absolute(url) {
      try { return new URL(String(url), location.href).toString(); } catch (e) { return String(url); }
    }
    Object.defineProperty(window, '__openLoungeNativeResolve', {
      configurable: false, enumerable: false, writable: false,
      value: function (id, ok, result, error) {
        var p = pending[id];
        if (!p) return;
        delete pending[id];
        clearTimeout(p.timer);
        if (ok) p.resolve(result); else p.reject(new Error(error || 'OpenLoungeNative error'));
      }
    });
    var readySent = false;
    function ready(source) {
      if (readySent) return;
      readySent = true;
      post({ __ol: 1, method: 'ready', value: source || 'page' });
    }
    var api = {
      __expo: true,
      platform: ${JSON.stringify(platform)},
      version: ${JSON.stringify(appVersion)},
      buildNumber: ${JSON.stringify(appBuild)},
      getVersion: function () { return ${JSON.stringify(appVersion)}; },
      getBuildNumber: function () { return ${JSON.stringify(appBuild)}; },
      capabilities: Object.freeze(['session', 'theme', 'ready', 'haptic', 'haptics', 'openAuth', 'openExternal', 'browser', 'camera', 'push', 'share', 'contacts', 'badge', 'biometrics', 'phoneAuth'${nativeCalls ? ", 'calls', 'nativeMedia'" : ''}]),
      // native call media (iOS app owns mic + transports + AVAudioSession; the page relays signaling)
      nativeMedia: function (cmd) { return call('nativeMedia', cmd, 30000); },
      msReply: function (id, ok, result, error) { post({ __ol: 1, method: 'msReply', value: { id: String(id), ok: !!ok, result: result === undefined ? null : result, error: error ? String(error) : undefined } }); },
      getPlatform: function () { return ${JSON.stringify(platform)}; },
      // the native side sets window.__olExpoPushToken and calls window.__olPushToken(token) when FCM hands one out
      getPushToken: function () { return typeof window.__olExpoPushToken === 'string' ? window.__olExpoPushToken : ''; },
      share: function (text, url) { post({ __ol: 1, method: 'share', value: { text: String(text || ''), url: String(url || '') } }); },
      // the page shows its explainer first; the result arrives via window.__olContacts(json)
      requestContacts: function () { post({ __ol: 1, method: 'requestContacts' }); },
      contactsPermission: function () { return 'prompt'; },
      openAppSettings: function () { post({ __ol: 1, method: 'openAppSettings' }); },
      requestNotificationPermission: function () { post({ __ol: 1, method: 'requestNotificationPermission' }); },
      setBadge: function (n) { post({ __ol: 1, method: 'setBadge', value: Number(n) || 0 }); },
      getSession: function () {
        return call('getSession').then(function (v) { return typeof v === 'string' ? v : null; });
      },
      setSession: function (json) {
        if (typeof json !== 'string') return Promise.reject(new TypeError('setSession expects a string'));
        return call('setSession', json).then(function () {});
      },
      clearSession: function () { return call('clearSession').then(function () {}); },
      ready: function () { ready('page'); },
      haptic: function (kind) { post({ __ol: 1, method: 'haptic', value: String(kind || 'light') }); },
      // 0.3.0 contract: same transport, the 7 portable types (unknown types are ignored natively); returns true if sent
      haptics: function (type) { return post({ __ol: 1, method: 'haptic', value: String(type || 'light') }); },
      openBrowser: function (url) { return post({ __ol: 1, method: 'openExternal', value: absolute(url) }); },
      openAuth: function (url) { return call('openAuth', absolute(url)).then(function () {}); },
      openExternal: function (url) { post({ __ol: 1, method: 'openExternal', value: absolute(url) }); },
      biometrics: Object.freeze({
        isAvailable: function () { return call('bioIsAvailable').then(function (v) { return v === true; }); },
        getEnabled: function () { return call('bioGetEnabled').then(function (v) { return v === true; }); },
        // waits for the Face ID / passcode sheet → generous timeout
        setEnabled: function (on) { return call('bioSetEnabled', !!on, 120000).then(function (v) { return v === true; }); }
      }),
      // native Firebase phone verification (silent APNs, no web reCAPTCHA); results via window.__olPhoneAuth(json)
      phoneAuthAvailable: function () { return true; },
      phoneAuthStart: function (id, phone) { post({ __ol: 1, method: 'phoneAuthStart', value: { id: String(id), phone: String(phone) } }); },
      phoneAuthConfirm: function (id, code) { post({ __ol: 1, method: 'phoneAuthConfirm', value: { id: String(id), code: String(code) } }); },
      // NATIVE_SPEC §5: raw JSON string messages ({type:"call:*"}), same transport as ReactNativeWebView.postMessage
      postMessage: function (s) {
        var bridge = window.ReactNativeWebView;
        if (!bridge || typeof bridge.postMessage !== 'function') return false;
        try { bridge.postMessage(String(s)); return true; } catch (e) { return false; }
      }
    };
    // build 18+: the page posts call:* messages and CallKit drives openlounge:native-call (engine.ts postNative)
    if (${nativeCalls ? 'true' : 'false'}) { try { window.__olNativeCalls = 1; window.__olNativeRingback = 2; } catch (e) {} }
    Object.defineProperty(window, 'OpenLoungeNative', { configurable: false, enumerable: true, writable: false, value: Object.freeze(api) });

    // Remember AudioContexts so audio can be resumed after an interruption (see audioResumeScript).
    // A Proxy construct trap keeps instanceof, statics and subclassing intact.
    try {
      var ctxs = window.__olAudioContexts = [];
      ['AudioContext', 'webkitAudioContext'].forEach(function (k) {
        var C = window[k];
        if (typeof C !== 'function' || typeof Proxy !== 'function' || typeof Reflect === 'undefined') return;
        var P = new Proxy(C, { construct: function (t, args, nt) {
          var c = Reflect.construct(t, args, nt);
          ctxs.push(c); if (ctxs.length > 16) ctxs.shift();
          return c;
        } });
        Object.defineProperty(window, k, { value: P, configurable: true, writable: true, enumerable: false });
      });
    } catch (e) {}

    // Native feel: no pinch / double-tap / input-focus zoom, no rubber band on the page, no long-press link
    // previews or selection callouts on UI chrome (inputs and [data-selectable] stay selectable).
    var CSS = 'html{touch-action:manipulation;-webkit-tap-highlight-color:transparent;overscroll-behavior:none}'
      + 'body{overscroll-behavior:none}'
      + 'a,img,svg,video,button,[role=button],[role=tab],[role=menuitem],[role=link],nav,header,label'
      + '{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}'
      + 'input,textarea,select,[contenteditable],[contenteditable] *,[data-selectable],[data-selectable] *'
      + '{-webkit-touch-callout:default;-webkit-user-select:text;user-select:text}';
    function lockViewport() {
      var head = document.head || document.getElementsByTagName('head')[0];
      if (!head) return;
      var m = document.querySelector('meta[name="viewport"]');
      if (!m) { m = document.createElement('meta'); m.setAttribute('name', 'viewport'); head.appendChild(m); }
      var c = m.getAttribute('content') || 'width=device-width, initial-scale=1, viewport-fit=cover';
      if (!/maximum-scale/.test(c)) c += ', maximum-scale=1';
      if (!/user-scalable/.test(c)) c += ', user-scalable=no';
      if (m.getAttribute('content') !== c) m.setAttribute('content', c);
      if (!document.getElementById('ol-native-css')) {
        var s = document.createElement('style');
        s.id = 'ol-native-css';
        s.textContent = CSS;
        head.appendChild(s);
      }
    }
    document.addEventListener('gesturestart', function (e) { e.preventDefault(); }, { passive: false });

    // Report the web app's theme (<html data-theme="dark|light">) so the status bar and launch colour match.
    var lastTheme = null;
    function sendTheme() {
      var t = document.documentElement && document.documentElement.getAttribute('data-theme');
      if ((t === 'dark' || t === 'light') && t !== lastTheme) {
        if (post({ __ol: 1, method: 'theme', value: t })) lastTheme = t;
      }
    }
    function watchTheme() {
      if (!document.documentElement) return;
      sendTheme();
      new MutationObserver(sendTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    }

    // Splash hand-off: the page can call OpenLoungeNative.ready(); otherwise report ready once the web app's own
    // loading screen (AuthGate, data-testid="splash") is gone and a frame has been painted.
    function autoReady() {
      var tries = 0;
      (function check() {
        if (readySent) return;
        var body = document.body;
        if (body && body.childElementCount > 0 && !document.querySelector('[data-testid="splash"]')) {
          requestAnimationFrame(function () { requestAnimationFrame(function () { ready('auto'); }); });
          return;
        }
        if (++tries < 120) setTimeout(check, 100);
      })();
    }

    function onDom() { lockViewport(); autoReady(); }
    if (document.documentElement) watchTheme(); else document.addEventListener('DOMContentLoaded', watchTheme);
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', onDom); else onDom();
    window.addEventListener('pageshow', function () { lastTheme = null; sendTheme(); });
  } catch (e) {}
})();
true;`;
}
