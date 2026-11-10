// The JavaScript the app injects into openlounge.app before any page script runs, and the small
// scripts it evaluates to answer the page. Transport: window.webkit.messageHandlers.ol.
//
//   window.OpenLoungeNative = {
//     platform "ios", version, buildNumber, capabilities, getPlatform(), getVersion(), getBuildNumber()
//     getSession() / setSession(json) / clearSession()     Keychain session store
//     ready()                                              page painted -> launch cover fades out
//     haptic(kind) / haptics(type)                         UIFeedbackGenerator
//     openAuth(url)                                        Google / Apple sign-in (ASWebAuthenticationSession)
//     openExternal(url) / openBrowser(url)                 SFSafariViewController (own pages stay in the app)
//     share(text, url), requestContacts(), contactsPermission(), openAppSettings()
//     requestNotificationPermission(), getPushToken(), setBadge(n)
//     biometrics { isAvailable(), getEnabled(), setEnabled(on) }   opt-in App Lock
//     phoneAuthStart(id, phone) / phoneAuthConfirm(id, code)       results via window.__olPhoneAuth(json)
//     nativeMedia(cmd) / msReply()                         call media: the app runs every call on
//                                                          OLTgcallsEngine (Pion over TURN)
//     postMessage(json)                                    page call messages {"type":"call:*"}
//   }
//
// Requests that return a value post {"__ol":1,"id","method","value"}; the app answers with
// window.__openLoungeNativeResolve(id, ok, result, error).
import Foundation

public enum OLBridgeScript {
    public static let handlerName = "ol"

    /// Capability names the Open Lounge page checks. "rtcP2P" and "ol-rc-v1" are the page's names
    /// for "this app owns call media"; with them the page hands every call to `nativeMedia`, and
    /// the app joins it on the Pion server over TURN relay only (see OLTgcallsInstance).
    public static let callCapabilities = ["calls", "nativeMedia", "nativeVideo", "rtcP2P", "ol-rc-v1"]
    public static let baseCapabilities = ["session", "theme", "ready", "haptic", "haptics", "openAuth", "openExternal", "browser",
                                          "camera", "push", "share", "contacts", "badge", "biometrics", "phoneAuth"]

    public static func capabilities(phoneAuth: Bool) -> [String] {
        baseCapabilities.filter { phoneAuth || $0 != "phoneAuth" } + callCapabilities
    }

    static func js(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [v], options: [.fragmentsAllowed]),
              var s = String(data: d, encoding: .utf8) else { return "null" }
        s.removeFirst(); s.removeLast()
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Resolve / reject one pending page request.
    public static func resolve(id: String, ok: Bool, result: Any?, error: String?) -> String {
        "window.__openLoungeNativeResolve&&window.__openLoungeNativeResolve(\(js(id)),\(ok ? "true" : "false"),\(js(result ?? NSNull())),\(js(error ?? NSNull())));true;"
    }

    /// window.dispatchEvent(new CustomEvent(name, {detail})).
    public static func event(_ name: String, _ detail: Any?) -> String {
        "(function(){try{window.dispatchEvent(new CustomEvent(\(js(name)),{detail:\(js(detail ?? NSNull()))}));}catch(e){}})();true;"
    }

    /// Call a page hook `window.<fn>(arg)` if the page defined it.
    public static func hook(_ fn: String, _ arg: Any) -> String {
        "(function(){try{window.\(fn)&&window.\(fn)(\(js(arg)));}catch(e){}})();true;"
    }

    public static func keyboard(visible: Bool, height: Double, duration: Double) -> String {
        let h = max(0, Int((visible ? height : 0).rounded()))
        return "(function(){try{document.documentElement.style.setProperty('--ol-keyboard-height','\(h)px');}catch(e){}})();"
            + event("openlounge:native-keyboard", ["visible": visible, "height": h, "duration": Int(duration.rounded())])
    }

    public static func pushToken(_ t: String) -> String {
        "window.__olExpoPushToken=\(js(t));window.__olPushToken&&window.__olPushToken(\(js(t)));true;"
    }

    /// Answer a ringing call in the loaded page. The page's hook returns false when it can't; the
    /// result comes back as the evaluation result.
    public static func acceptCall(_ callId: String) -> String {
        "(function(){try{return !!(window.__olAcceptCall&&window.__olAcceptCall(\(js(callId))));}catch(e){return false;}})();"
    }

    /// Defined before any page script (WKUserScript, document start, main frame only).
    public static func injected(version: String, build: String, phoneAuth: Bool) -> String {
        let caps = js(capabilities(phoneAuth: phoneAuth))
        return """
        (function(){
          try {
            if (window.OpenLoungeNative) return;
            var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            if (!H) return;
            var pending = {}, seq = 0;
            function post(msg) { try { H.postMessage(JSON.stringify(msg)); return true; } catch (e) { return false; } }
            function call(method, value, timeoutMs) {
              return new Promise(function (resolve, reject) {
                var id = 'ol' + Date.now().toString(36) + '_' + (++seq);
                var timer = setTimeout(function () { if (pending[id]) { delete pending[id]; reject(new Error('OpenLoungeNative ' + method + ' timed out')); } }, timeoutMs || 10000);
                pending[id] = { resolve: resolve, reject: reject, timer: timer };
                var msg = { __ol: 1, id: id, method: method };
                if (value !== undefined) msg.value = value;
                if (!post(msg)) { clearTimeout(timer); delete pending[id]; reject(new Error('OpenLoungeNative unavailable')); }
              });
            }
            function absolute(url) { try { return new URL(String(url), location.href).toString(); } catch (e) { return String(url); } }
            Object.defineProperty(window, '__openLoungeNativeResolve', { configurable: false, enumerable: false, writable: false,
              value: function (id, ok, result, error) {
                var p = pending[id]; if (!p) return;
                delete pending[id]; clearTimeout(p.timer);
                if (ok) p.resolve(result); else p.reject(new Error(error || 'OpenLoungeNative error'));
              } });
            var readySent = false;
            function ready(source) { if (readySent) return; readySent = true; post({ __ol: 1, method: 'ready', value: source || 'page' }); }
            var api = {
              platform: 'ios', version: \(js(version)), buildNumber: \(js(build)),
              getVersion: function () { return \(js(version)); },
              getBuildNumber: function () { return \(js(build)); },
              getPlatform: function () { return 'ios'; },
              capabilities: Object.freeze(\(caps)),
              nativeMedia: function (cmd) { return call('nativeMedia', cmd, cmd && cmd.op === 'connect' ? 120000 : 30000); },
              msReply: function () {},
              getPushToken: function () { return typeof window.__olExpoPushToken === 'string' ? window.__olExpoPushToken : ''; },
              share: function (text, url) { post({ __ol: 1, method: 'share', value: { text: String(text || ''), url: String(url || '') } }); },
              requestContacts: function () { post({ __ol: 1, method: 'requestContacts' }); },
              contactsPermission: function () { return 'prompt'; },
              openAppSettings: function () { post({ __ol: 1, method: 'openAppSettings' }); },
              requestNotificationPermission: function () { post({ __ol: 1, method: 'requestNotificationPermission' }); },
              setBadge: function (n) { post({ __ol: 1, method: 'setBadge', value: Number(n) || 0 }); },
              getSession: function () { return call('getSession').then(function (v) { return typeof v === 'string' ? v : null; }); },
              setSession: function (json) {
                if (typeof json !== 'string') return Promise.reject(new TypeError('setSession expects a string'));
                return call('setSession', json).then(function () {});
              },
              clearSession: function () { return call('clearSession').then(function () {}); },
              ready: function () { ready('page'); },
              haptic: function (kind) { post({ __ol: 1, method: 'haptic', value: String(kind || 'light') }); },
              haptics: function (type) { return post({ __ol: 1, method: 'haptic', value: String(type || 'light') }); },
              openBrowser: function (url) { return post({ __ol: 1, method: 'openExternal', value: absolute(url) }); },
              openAuth: function (url) { return call('openAuth', absolute(url)).then(function () {}); },
              openExternal: function (url) { post({ __ol: 1, method: 'openExternal', value: absolute(url) }); },
              biometrics: Object.freeze({
                isAvailable: function () { return call('bioIsAvailable').then(function (v) { return v === true; }); },
                getEnabled: function () { return call('bioGetEnabled').then(function (v) { return v === true; }); },
                setEnabled: function (on) { return call('bioSetEnabled', !!on, 120000).then(function (v) { return v === true; }); }
              }),
              phoneAuthAvailable: function () { return \(phoneAuth ? "true" : "false"); },
              phoneAuthStart: function (id, phone) { post({ __ol: 1, method: 'phoneAuthStart', value: { id: String(id), phone: String(phone) } }); },
              phoneAuthConfirm: function (id, code) { post({ __ol: 1, method: 'phoneAuthConfirm', value: { id: String(id), code: String(code) } }); },
              postMessage: function (s) { try { H.postMessage(String(s)); return true; } catch (e) { return false; } }
            };
            try { window.__olNativeCalls = 1; } catch (e) {}
            Object.defineProperty(window, 'OpenLoungeNative', { configurable: false, enumerable: true, writable: false, value: Object.freeze(api) });

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
                var s = document.createElement('style'); s.id = 'ol-native-css'; s.textContent = CSS; head.appendChild(s);
              }
            }
            document.addEventListener('gesturestart', function (e) { e.preventDefault(); }, { passive: false });
            var lastTheme = null;
            function sendTheme() {
              var t = document.documentElement && document.documentElement.getAttribute('data-theme');
              if ((t === 'dark' || t === 'light') && t !== lastTheme && post({ __ol: 1, method: 'theme', value: t })) lastTheme = t;
            }
            function watchTheme() {
              if (!document.documentElement) return;
              sendTheme();
              new MutationObserver(sendTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
            }
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
        true;
        """
    }
}
