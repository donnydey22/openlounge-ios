// The page's own CallOverlay (openlounge.app) always renders under the native CallScreen. With the native
// call UI, hide its non-incoming states (outgoing, connecting, active, ended) so the only call screen is the
// first-design native one: no web call view after hang-up, none under the minimized green bar.
// Same script as Android CallWebOverlay.HIDE_JS. The DOM stays, so the read-only photo / presence peeks still work.
// Incoming stays on the page in the foreground until the page posts call:incoming there (web change, not deployed).
enum CallWebOverlay {
    static let hideJS = "(function(){try{var id='ol-native-call-ui';function add(){if(document.getElementById(id))return;var s=document.createElement('style');s.id=id;s.textContent='[data-testid=\"call-screen\"]:not([data-ui=\"incoming\"]){visibility:hidden!important;pointer-events:none!important}';(document.head||document.documentElement).appendChild(s);}add();if(!window.__olHideCallUi){window.__olHideCallUi=1;new MutationObserver(add).observe(document.documentElement,{childList:true,subtree:true});}}catch(e){}})()"
}
