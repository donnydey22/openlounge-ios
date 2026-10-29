import ExpoModulesCore

// JS API (src/calls.ts). Everything that touches CallKit/PushKit state runs on the main queue in OLCallManager.
public final class OpenLoungeCallsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OpenLoungeCalls")

    Events("onCallAction", "onVoipToken")

    OnCreate {
      OLCallManager.shared.attach(self)
    }

    OnDestroy {
      OLCallManager.shared.detach(self)
    }

    // JS has added its listeners: from now on actions are emitted as events instead of being queued.
    Function("ready") { () -> String in
      return OLCallManager.shared.markReady()
    }

    Function("getVoipToken") { () -> String in
      return OLCallManager.shared.voipToken
    }

    Function("handlePageMessage") { (json: String) in
      DispatchQueue.main.async { OLCallManager.shared.handlePage(json) }
    }

    // Short-lived access token (1 h) so a CallKit "Decline" can POST /api/calls/<id>/decline without the WebView.
    Function("setAuth") { (token: String, expMs: Double) in
      OLCallAuth.save(token: token, expMs: expMs)
    }

    Function("endCall") { (callId: String, reason: String) in
      DispatchQueue.main.async { OLCallManager.shared.endExternally(callId: callId, reason: reason) }
    }
  }
}

public final class OpenLoungeCallsAppDelegate: ExpoAppDelegateSubscriber {
  // PushKit must be registered at launch: iOS relaunches a killed app in the background to deliver a VoIP push and
  // requires a CallKit call to be reported before the delegate's completion handler returns.
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    OLCallManager.shared.start()
    return true
  }
}
