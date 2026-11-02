import ExpoModulesCore

// JS API (src/calls.ts). Everything that touches CallKit/PushKit state runs on the main queue in OLCallManager.
public final class OpenLoungeCallsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("OpenLoungeCalls")

    Events("onCallAction", "onVoipToken", "onMsRequest", "onLaneEvent")

    OnCreate {
      OLCallManager.shared.attach(self)
      OLLaneBridge.shared.module = self
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

    // b75 single path (Android → iPhone incoming audio): Swift RTCPeerConnection lane on StreamWebRTC.
    AsyncFunction("laneConnect") { (callId: String, nativeConn: String, iceJson: String) async throws -> Bool in
      let ice = ((try? JSONSerialization.jsonObject(with: Data(iceJson.utf8))) as? [[String: Any]]) ?? []
      let lane: OLNativeAudioLane = await MainActor.run {
        OLNativeAudioLane.shared?.close()
        let l = OLNativeAudioLane(callId: callId, nativeConn: nativeConn, iceServers: ice,
                                  req: { e, d in try await OLLaneBridge.shared.request(e, d) },
                                  emit: { d in var x = d; x["callId"] = callId; OLLaneBridge.shared.emitLane(x) })
        OLNativeAudioLane.shared = l
        return l
      }
      do { try await lane.connect() } catch { await MainActor.run { lane.close() }; throw error }
      return true
    }

    Function("msResponse") { (id: String, ok: Bool, json: String, error: String) in
      OLLaneBridge.shared.finish(id, ok: ok, json: json, error: error)
    }

    Function("laneControl") { (op: String, flag: Bool) -> Bool in
      DispatchQueue.main.async {
        guard let l = OLNativeAudioLane.shared else { return }
        switch op {
        case "mute": l.setMuted(flag)
        case "close": l.close()
        case "sync": Task { @MainActor in await l.syncConsumers() }
        default: break
        }
      }
      return OLNativeAudioLane.shared?.connected ?? false
    }

    Function("endCall") { (callId: String, reason: String) in
      DispatchQueue.main.async { OLCallManager.shared.endExternally(callId: callId, reason: reason) }
    }
  }
}

public final class OpenLoungeCallsAppDelegate: ExpoAppDelegateSubscriber {
  // call_cancel (caller hung up / answered elsewhere / timeout) arrives as a background data push. Ending the CallKit
  // ring here is native, so it works even when the JS bundle is not running (app launched by PushKit, then killed).
  public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    if (userInfo["type"] as? String) == "call_cancel", let callId = userInfo["callId"] as? String {
      let reason = (userInfo["reason"] as? String) ?? ""
      DispatchQueue.main.async { OLCallManager.shared.endExternally(callId: callId, reason: reason) }
      completionHandler(.newData)
      return
    }
    completionHandler(.noData)
  }

  // PushKit must be registered at launch: iOS relaunches a killed app in the background to deliver a VoIP push and
  // requires a CallKit call to be reported before the delegate's completion handler returns.
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    OLCallManager.shared.start()
    return true
  }
}
