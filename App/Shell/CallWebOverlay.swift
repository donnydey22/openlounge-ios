// The page's own CallOverlay (openlounge.app) always renders under the native CallScreen. Hide every state so
// incoming shows only the native banner and no web call view appears after hang-up or under the minimized green bar.
// Same script as Android CallWebOverlay.HIDE_JS. The DOM stays, so the read-only photo / presence peeks still work.
enum CallWebOverlay {
    static let hideJS = "(function(){try{var id='ol-native-call-ui';function add(){if(document.getElementById(id))return;var s=document.createElement('style');s.id=id;s.textContent='[data-testid=\"call-screen\"]{visibility:hidden!important;pointer-events:none!important}';(document.head||document.documentElement).appendChild(s);}add();if(!window.__olHideCallUi){window.__olHideCallUi=1;new MutationObserver(add).observe(document.documentElement,{childList:true,subtree:true});}}catch(e){}})()"
}
