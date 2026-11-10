// ShellViewController — Open Lounge is the openlounge.app web app (chat, rooms, profile, call
// screens and call control) in a WKWebView, plus what only the phone can do: the session in the
// Keychain, App Lock, push, contacts, haptics, share, sign-in sheets, CallKit, and call media on
// OLTgcallsEngine. The page and the app talk through window.OpenLoungeNative (OLBridgeScript).
import AuthenticationServices
import CallKit
import Combine
import Network
import OLShellCore
import SafariServices
import SwiftUI
import UIKit
import WebKit

final class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
    ASWebAuthenticationPresentationContextProviding, ShellHost {
    private var webView: WKWebView!
    private let statusStrip = UIView()
    private var launchHost: UIHostingController<LaunchCover>?
    private var offlineHost: UIHostingController<OfflineCover>?
    private var lockHost: UIHostingController<LockCover>?
    private var callHost: UIHostingController<CallLayer>!
    private var bag = Set<AnyCancellable>()

    private var light = false
    private var everLoaded = false
    private var currentURL = OLAppURL.startURL
    private var pushQueue = OLForegroundPushQueue()
    private var retryAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var offline = false
    private let path = NWPathMonitor()
    private var lastPathType = ""
    private var authSession: ASWebAuthenticationSession?
    private var handledCodes = Set<String>()
    private var session: (token: String, exp: Double)?
    private var voipSent = (key: "", at: Date.distantPast)

    // App Lock
    private var lock: OLLockPolicy.Lock = .checking
    private var lockEnabled = false
    private var prompting = false
    private var backgroundedAt: TimeInterval = 0
    private var lockActions = false
    private var lockFailed = false

    private static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    var origin: String { OLAppURL.originOf(currentURL) }
    var accessToken: String? {
        guard let s = session, s.exp > Date().timeIntervalSince1970 * 1000 + 5_000 else { return nil }
        return s.token
    }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        light = KeychainStore.prefs.get("openlounge.theme") == "light"
        view.backgroundColor = light ? ShellColor.light : ShellColor.dark

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.applicationNameForUserAgent = "OpenLounge/ios/\(Self.version)(\(Self.build)) OpenLoungeiOS/\(Self.version)"
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: OLBridgeScript.injected(version: Self.version, build: Self.build, phoneAuth: PhoneAuth.available),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(WeakMessageHandler(self), name: OLBridgeScript.handlerName)
        config.userContentController = ucc

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        statusStrip.translatesAutoresizingMaskIntoConstraints = false
        statusStrip.backgroundColor = view.backgroundColor
        view.addSubview(statusStrip)
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            statusStrip.topAnchor.constraint(equalTo: view.topAnchor),
            statusStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusStrip.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let call = CallController.shared
        callHost = UIHostingController(rootView: CallLayer(call: call))
        callHost.view.backgroundColor = .clear
        cover(callHost)
        callHost.view.isHidden = true
        call.$visible.combineLatest(call.$incomingVisible).receive(on: RunLoop.main)
            .sink { [weak self] v, i in self?.callHost.view.isHidden = !(v || i); self?.raiseCovers() }.store(in: &bag)

        showLaunch()
        wireServices()
        observeApp()
        startPathMonitor()
        readLockSetting()
        KeychainStore.session.getSession { [weak self] json in DispatchQueue.main.async { self?.sessionChanged(json) } }
        load(OLAppURL.startURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.hideLaunch() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { light ? .darkContent : .lightContent }

    private func cover(_ c: UIViewController) {
        addChild(c)
        c.view.frame = view.bounds
        c.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(c.view)
        c.didMove(toParent: self)
    }

    private func uncover(_ c: UIViewController?) {
        guard let c else { return }
        c.willMove(toParent: nil)
        c.view.removeFromSuperview()
        c.removeFromParent()
    }

    /// Order, top to bottom: incoming card / call screen, App Lock, offline, launch.
    private func raiseCovers() {
        if let o = offlineHost { view.bringSubviewToFront(o.view) }
        if let l = launchHost { view.bringSubviewToFront(l.view) }
        if let k = lockHost { view.bringSubviewToFront(k.view) }
        view.bringSubviewToFront(callHost.view)
    }

    private func load(_ url: String) {
        guard let u = URL(string: url) else { return }
        currentURL = url
        var r = URLRequest(url: u)
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.load(r)
    }

    private func wireServices() {
        NativeMedia.shared.host = self
        CallCenter.shared.host = self
        CallController.shared.host = self
        CallCenter.shared.onVoipToken = { [weak self] _ in self?.syncVoip() }
        let push = Push.shared
        push.onToken = { [weak self] t in self?.js(OLBridgeScript.pushToken(t)) }
        push.onForeground = { [weak self] d in self?.foregroundPush(d) }
        push.onOpenPath = { [weak self] p in self?.navigate(OLAppURL.originOf(self?.currentURL) + p) }
        push.onCallCancel = { id in CallCenter.shared.endRing(id, reason: .remoteEnded) }
    }

    // MARK: page scripting

    private func js(_ s: String) { webView?.evaluateJavaScript(s, completionHandler: nil) }

    func peekCallPresence(_ done: @escaping (String?) -> Void) {
        let script = "(function(){try{var el=document.querySelector('[data-testid=\'call-screen\'] [data-presence]')||document.querySelector('[data-testid=\'incoming-call\'] [data-presence]');if(!el)return '';return el.getAttribute('data-presence')||'offline';}catch(e){return '';}})()"
        guard let webView else { done(nil); return }
        webView.evaluateJavaScript(script) { r, _ in
            done(r as? String)
        }
    }

    private func reply(_ id: String, _ ok: Bool, _ result: Any? = nil, _ error: String? = nil) {
        js(OLBridgeScript.resolve(id: id, ok: ok, result: result, error: error))
    }

    func dispatchNativeCall(_ detail: [String: Any]) { js(OLBridgeScript.event("openlounge:native-call", detail)) }
    func emitNativeMedia(_ detail: [String: Any]) { js(OLBridgeScript.event("openlounge:native-media", detail)) }

    func answerInPage(callId: String) {
        let url = OLAppURL.callAcceptURL(origin: origin, callId: callId)
        guard everLoaded, !offline else { return load(url) }
        webView.evaluateJavaScript(OLBridgeScript.acceptCall(callId)) { [weak self] r, _ in
            if (r as? Bool) != true { self?.load(url) }
        }
    }

    func unlockForCall() {
        lock = .unlocked
        lockActions = false
        lockFailed = false
        renderLock()
    }

    private func navigate(_ url: String) {
        guard OLAppURL.isAppURL(url) else { return }
        if everLoaded && !offline {
            js("location.assign(\(OLBridgeScriptJS.quote(url)));true;")
        } else {
            load(url)
        }
    }

    private func foregroundPush(_ d: [String: String]) {
        guard everLoaded, UIApplication.shared.applicationState == .active else { return pushQueue.enqueue(d) }
        js(OLBridgeScript.event("openlounge:native-notification", d))
    }

    private func flushPushes() {
        guard everLoaded, UIApplication.shared.applicationState == .active else { return }
        for d in pushQueue.drain() { js(OLBridgeScript.event("openlounge:native-notification", d)) }
    }

    // MARK: bridge

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? String
        let u = OLAppURL.resolveScriptMessageURL(
            frameURL: message.frameInfo.request.url?.absoluteString,
            webViewURL: webView.url?.absoluteString,
            currentURL: currentURL,
            origin: origin
        )
        let req = body.flatMap(OLBridgeMessage.parse)
        guard message.frameInfo.isMainFrame, OLAppURL.isAppURL(u), let req else {
            if let id = OLAppURL.bridgeRequestId(from: body) {
                reply(id, false, nil, "bridge-rejected")
            }
            return
        }
        switch req {
        case let .theme(t): setTheme(light: t == "light", fromPage: true)
        case .ready: hideLaunch()
        case let .haptic(k): Haptics.play(k)
        case let .openExternal(url): if OLAppURL.isAppURL(url) { navigate(url) } else { openOutside(url) }
        case let .share(text, url):
            var items: [Any] = []
            if !text.isEmpty { items.append(text) }
            if let u = URL(string: url), !url.isEmpty { items.append(u) }
            guard !items.isEmpty else { return }
            present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
        case .requestContacts:
            ContactsReader.read { [weak self] json in DispatchQueue.main.async { self?.js(OLBridgeScript.hook("__olContacts", json)) } }
        case .openAppSettings:
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        case .requestNotificationPermission: Push.shared.requestPermission()
        case let .setBadge(n): Push.shared.setBadge(n)
        case let .phoneAuthStart(id, phone):
            PhoneAuth.start(id: id, phone: phone) { [weak self] r in DispatchQueue.main.async { self?.phoneAuthResult(r) } }
        case let .phoneAuthConfirm(id, code):
            PhoneAuth.confirm(id: id, code: code) { [weak self] r in DispatchQueue.main.async { self?.phoneAuthResult(r) } }
        case let .call(m):
            CallCenter.shared.onPage(m)
            CallController.shared.onPage(m)
            if let raw = body, CallPresence.hasField(inJSON: raw) {
                // Explicit field, including "offline" (hides the dot). Empty peek does not clear.
                CallController.shared.setPresenceFromMessage(CallPresence.field(fromJSON: raw))
            }
            if case .connected = m { unlockForCall() }
        case let .nativeMedia(id, cmd):
            NativeMedia.shared.handle(cmd) { [weak self] ok, r, e in self?.reply(id, ok, r, e) }
        case let .getSession(id):
            KeychainStore.session.getSession { [weak self] v in DispatchQueue.main.async { self?.reply(id, true, v) } }
        case let .setSession(id, value):
            KeychainStore.session.setSession(value) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.reply(id, ok, nil, ok ? nil : "keychain")
                    self?.sessionChanged(value)
                }
            }
        case let .clearSession(id):
            if let t = CallCenter.shared.voipToken, let a = accessToken { CallAPI.postVoipToken(origin: origin, token: t, access: a, remove: true) }
            voipSent = ("", .distantPast)
            KeychainStore.session.clearSession { [weak self] in
                DispatchQueue.main.async { self?.reply(id, true); self?.sessionChanged(nil) }
            }
        case let .openAuth(id, url):
            guard OLAppURL.isNativeAuthStart(url) else { return reply(id, false, nil, "openAuth: unsupported URL") }
            reply(id, true)
            runAuth(url)
        case let .bioIsAvailable(id): reply(id, true, AppLock.isAvailable)
        case let .bioGetEnabled(id): reply(id, true, AppLock.enabled)
        case let .bioSetEnabled(id, on):
            prompting = true
            AppLock.setEnabled(on) { [weak self] now in
                self?.prompting = false
                self?.lockEnabled = now
                self?.reply(id, true, now)
            }
        }
    }

    private func phoneAuthResult(_ r: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: r), let s = String(data: d, encoding: .utf8) else { return }
        js(OLBridgeScript.hook("__olPhoneAuth", s))
    }

    private func sessionChanged(_ json: String?) {
        session = OLSessionAccess.from(json)
        syncVoip()
    }

    /// PushKit token -> server whenever both it and a fresh access token are known; at most every
    /// 6 h for the same token and account.
    private func syncVoip() {
        guard let t = CallCenter.shared.voipToken, let a = accessToken else { return }
        let key = "\(t):\(a.prefix(24))"
        if voipSent.key == key && Date().timeIntervalSince(voipSent.at) < 6 * 3600 { return }
        voipSent = (key, Date())
        CallAPI.postVoipToken(origin: origin, token: t, access: a) { [weak self] st in
            if !(200..<300).contains(st) { DispatchQueue.main.async { self?.voipSent = ("", .distantPast) } }
        }
    }

    // MARK: theme, launch, offline

    private func setTheme(light l: Bool, fromPage: Bool) {
        light = l
        let bg = l ? ShellColor.light : ShellColor.dark
        view.backgroundColor = bg
        statusStrip.backgroundColor = bg
        setNeedsStatusBarAppearanceUpdate()
        if fromPage { KeychainStore.prefs.set("openlounge.theme", l ? "light" : "dark") }
    }

    private func showLaunch() {
        let h = UIHostingController(rootView: LaunchCover(light: light))
        launchHost = h
        cover(h)
    }

    private func hideLaunch() {
        guard let h = launchHost else { return }
        launchHost = nil
        UIView.animate(withDuration: 0.25, animations: { h.view.alpha = 0 }, completion: { [weak self] _ in self?.uncover(h) })
    }

    private func goOffline() {
        hideLaunch()
        if !offline {
            offline = true
            let h = UIHostingController(rootView: OfflineCover(light: light) { [weak self] in self?.retryNow() })
            offlineHost = h
            cover(h)
            raiseCovers()
        }
        retryWork?.cancel()
        let delay = min(30, 2 * pow(2, Double(min(retryAttempt, 4))))
        retryAttempt += 1
        let w = DispatchWorkItem { [weak self] in self?.retryNow() }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func retryNow() {
        retryWork?.cancel()
        if everLoaded { webView.reload() } else { load(currentURL) }
    }

    private func online() {
        retryWork?.cancel()
        retryAttempt = 0
        guard offline else { return }
        offline = false
        uncover(offlineHost)
        offlineHost = nil
    }

    private func startPathMonitor() {
        path.pathUpdateHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                let t = p.usesInterfaceType(.wifi) ? "wifi" : p.usesInterfaceType(.cellular) ? "cellular" : p.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"
                if p.status == .satisfied {
                    if !self.lastPathType.isEmpty && self.lastPathType != t {
                        self.js("try{window.__olNetworkChanged&&window.__olNetworkChanged(\(OLBridgeScriptJS.quote(t)))}catch(e){};true;")
                    }
                    self.lastPathType = t
                    if self.offline { self.retryNow() }
                }
            }
        }
        path.start(queue: DispatchQueue(label: "ol.path"))
    }

    // MARK: App Lock

    private func readLockSetting() {
        lockEnabled = AppLock.enabled
        if OLLockPolicy.shouldLock(enabled: lockEnabled, backgroundedAt: 0, now: Date().timeIntervalSince1970) {
            lock = .locked
            renderLock()
            promptUnlock(otherWay: false)
        } else {
            lock = .unlocked
        }
    }

    private func promptUnlock(otherWay: Bool) {
        guard !prompting else { return }
        prompting = true
        lockActions = false
        renderLock()
        AppLock.authenticate(otherWay ? "Enter your iPhone passcode to unlock" : "Unlock Open Lounge") { [weak self] r in
            guard let self else { return }
            self.prompting = false
            switch r {
            case .success:
                self.lock = .unlocked
                self.lockFailed = false
            case .unavailable where !AppLock.isAvailable:
                AppLock.setFlag(false) // passcode removed: never lock people out of their own app
                self.lockEnabled = false
                self.lock = .unlocked
            default:
                self.lockFailed = r == .failed
                self.lockActions = true
            }
            self.renderLock()
            self.reportVisibility()
        }
    }

    private func renderLock(privacy: Bool = false) {
        let covering = lock != .unlocked || privacy
        CallController.shared.lockCovering = lock != .unlocked
        if covering {
            let v = LockCover(showActions: lock == .locked && lockActions, failed: lockFailed,
                              unlock: { [weak self] in self?.promptUnlock(otherWay: false) },
                              otherWay: { [weak self] in self?.promptUnlock(otherWay: true) })
            if let h = lockHost { h.rootView = v } else { let h = UIHostingController(rootView: v); lockHost = h; cover(h) }
            raiseCovers()
        } else {
            uncover(lockHost)
            lockHost = nil
        }
    }

    private func reportVisibility() {
        let active = UIApplication.shared.applicationState == .active
        js(OLBridgeScript.event("openlounge:native-lock", ["locked": lock != .unlocked]))
        js(OLBridgeScript.event("openlounge:native-visibility", ["visible": OLLockPolicy.shouldReportVisible(appActive: active, lock: lock)]))
    }

    private func observeApp() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.prompting else { return }
            self.backgroundedAt = Date().timeIntervalSince1970
            self.js(OLBridgeScript.event("openlounge:native-visibility", ["visible": false]))
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.prompting else { return }
            if self.lockEnabled { self.renderLock(privacy: true) }
            self.reportVisibility()
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.prompting else { return }
            let since = self.backgroundedAt
            self.backgroundedAt = 0
            if since > 0, self.lock == .unlocked, !NativeMedia.shared.isActive,
               OLLockPolicy.shouldLock(enabled: self.lockEnabled, backgroundedAt: since, now: Date().timeIntervalSince1970) {
                self.lock = .locked
                self.renderLock()
                self.promptUnlock(otherWay: false)
            } else {
                self.renderLock()
            }
            self.reportVisibility()
            self.flushPushes()
            if !NativeMedia.shared.isActive { self.js(OLBridgeScriptJS.audioResume) }
            if self.offline { self.retryNow() }
        }
        nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] n in
            let h = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            let d = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            self?.js(OLBridgeScript.keyboard(visible: true, height: Double(h), duration: d * 1000))
        }
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] n in
            let d = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            self?.js(OLBridgeScript.keyboard(visible: false, height: 0, duration: d * 1000))
        }
    }

    // MARK: links and sign-in

    func handleIncomingURL(_ url: String) {
        if OLAppURL.isCallAcceptPath(url) { unlockForCall() }
        guard let t = OLAppURL.resolveIncomingLink(url, currentURL: currentURL) else { return }
        if let c = t.code {
            guard !handledCodes.contains(c) else { return }
            handledCodes.insert(c)
        }
        navigate(t.url)
    }

    private func runAuth(_ start: String) {
        guard authSession == nil, let u = URL(string: start) else { return }
        let s = ASWebAuthenticationSession(url: u, callbackURLScheme: OLAppURL.authCallbackScheme) { [weak self] url, _ in
            DispatchQueue.main.async {
                self?.authSession = nil
                if let url { self?.handleIncomingURL(url.absoluteString) }
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        authSession = s
        if !s.start() { authSession = nil }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }

    private func openOutside(_ url: String) {
        let s = OLAppURL.schemeOf(url)
        guard let u = URL(string: url) else { return }
        if s == "http" || s == "https" {
            guard presentedViewController == nil else { return UIApplication.shared.open(u) }
            let sf = SFSafariViewController(url: u)
            sf.preferredControlTintColor = UIColor(ShellColor.accent)
            sf.dismissButtonStyle = .done
            present(sf, animated: true)
        } else {
            UIApplication.shared.open(u)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url?.absoluteString else { return decisionHandler(.cancel) }
        let scheme = OLAppURL.schemeOf(url)
        let top = action.targetFrame?.isMainFrame ?? true
        switch scheme {
        case "about", "blob", "data":
            decisionHandler(.allow)
        case OLAppURL.scheme:
            handleIncomingURL(url)
            decisionHandler(.cancel)
        case "http", "https":
            if OLAppURL.isAppURL(url) {
                if top && OLAppURL.isNativeAuthStart(url) { runAuth(url); return decisionHandler(.cancel) } // Google / Apple refuse embedded sign-in
                if top { currentURL = url }
                return decisionHandler(.allow)
            }
            if !top { return decisionHandler(.allow) }
            openOutside(url)
            decisionHandler(.cancel)
        default:
            if let u = action.request.url { UIApplication.shared.open(u) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let r = response.response as? HTTPURLResponse, r.statusCode >= 500,
           let u = r.url?.absoluteString, OLAppURL.isAppURL(u) {
            decisionHandler(.cancel)
            return goOffline()
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        everLoaded = true
        if let u = webView.url?.absoluteString, OLAppURL.isAppURL(u) { currentURL = u }
        online()
        hideLaunch()
        flushPushes()
        reportVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Push.shared.start() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }

    private func loadFailed(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204)) { return }
        goOffline()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url?.absoluteString {
            if OLAppURL.isAppURL(url) { navigate(url) }
            else if OLAppURL.schemeOf(url) == OLAppURL.scheme { handleIncomingURL(url) }
            else { openOutside(url) }
        }
        return nil
    }

    /// Microphone / camera for the page itself (live rooms, profile photo) on its own host only.
    /// During a call the app owns both, so the page gets neither.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let mainHost = webView.url?.host?.lowercased() ?? ""
        let ok = frame.isMainFrame && origin.protocol == "https" && OLAppURL.isAppHost(origin.host) && origin.host.lowercased() == mainHost
            && !NativeMedia.shared.isActive
        decisionHandler(ok ? .grant : .deny)
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

enum OLBridgeScriptJS {
    static func quote(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(d.dropFirst().dropLast())
    }

    /// After an interruption or the app coming back: resume AudioContexts and paused stream
    /// elements of live rooms (never during a call).
    static let audioResume = """
    (function(){try{var n=0;var list=window.__olAudioContexts||[];
    for(var i=0;i<list.length;i++){var c=list[i];if(c&&(c.state==='suspended'||c.state==='interrupted')){try{var r=c.resume();if(r&&r.catch)r.catch(function(){});n++;}catch(e){}}}
    var els=document.querySelectorAll('audio,video');
    for(var j=0;j<els.length;j++){var el=els[j];if(el.srcObject&&el.paused&&!el.ended&&!el.muted&&el.autoplay){try{var p=el.play();if(p&&p.catch)p.catch(function(){});n++;}catch(e){}}}
    window.dispatchEvent(new CustomEvent('openlounge:native-audio-resume',{detail:{reason:'foreground',kicked:n}}));}catch(e){}})();true;
    """
}
