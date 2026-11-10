# Open Lounge iOS

The full Open Lounge app (chat, rooms, profile, calls) with one-to-one audio and video calls on the
Open Lounge Pion engine, relayed over TURN. One codebase, one path, the same as the Android olcall build.

```
openlounge.app in WKWebView (App/Shell)  chat, rooms, profile, call screens, call control
  call control: the page starts / accepts / reads the call on its signed-in realtime socket (Railway)
  page -> OpenLoungeNative.nativeMedia({op:"connect", callId, media, video})      (App/Calls/NativeMedia)
    -> permission gate (mic, or camera + mic)
    -> OLTgcallsEngine: wss://turn.openlounge.app/v1/call  join {token} -> joined {key, isOutgoing, iceServers}
    -> OLTgcallsInstance (tgcalls, TgVoipWebrtc.xcframework), relay only through coturn TURN
  ringing: PushKit VoIP push / page call:incoming -> CallKit (App/Calls/CallCenter); Answer -> the page accepts
```

| App shell | |
|---|---|
| `App/Shell/ShellViewController.swift` | WKWebView, OpenLoungeNative bridge, navigation rules, offline / launch / App Lock covers |
| `OLCall/Sources/OLShellCore/` | pure Swift rules with tests: app URLs and links, bridge messages, injected script, App Lock timing, ring pushes, media commands |
| `App/Shell/KeychainStore.swift` | session + prefs in the Keychain (same items as build 128, so people stay signed in after the update) |
| `App/Shell/Push.swift`, `PhoneAuth.swift` | FCM push (Firebase 12.19.3 via SPM, static) and Firebase phone sign-in |
| `App/Calls/CallCenter.swift` | CallKit + PushKit |
| `App/Calls/CallController.swift` | the app's call screen state (App/UI) |

| iOS | Android twin |
|---|---|
| `OLCall/Sources/OLCall/OLTgcallsEngine.swift` | `OlTgcallsEngine.kt` |
| `OLCall/Sources/OLCallCore/OLCallStates.swift` | `OlCallStates.kt` |
| `OLCall/Sources/OLCallCore/OLRtcServers.swift` | `OlRtcServers.kt` |
| `OLCall/Sources/OLCallCore/OLVersions.swift` | `OlVersions.kt` |
| `OLCall/Sources/OLCall/OLBreadcrumbs.swift` | `OlBreadcrumbs.kt` |
| `OLCall/Sources/OLCallCore/OLCallMedia.swift` | app-side CallMedia check |
| `App/Calls/NativeMedia.swift` | app-side call media (`nativeMedia` ops, as Android's bridge) |

- **Audio session:** `OLCallAudioDevice` is the only owner of `AVAudioSession`. Nothing else configures or activates it.
- **State log:** `olcall state <from> -> <to> reason=<r> t=<ms> call=<id>` over idle, joining, offering, answering, connected and failed, with the same reason tags as Android.
- **Permissions:** nothing at launch. An audio call asks for the microphone. A video call asks for the camera and the microphone in one flow. Turning video on mid-call asks for the camera only. A denial ends that call or that toggle silently, with no re-prompt.
- **UI:** the call screen layout, design tokens, squircle and avatar come from the first Open Lounge call UI in this repository's history: `d6135f0` (2026-11-04, call screen), `9c851a0` (2026-11-04, squircle avatar) and `325110e` (2026-10-14, incoming card).

- **Outbound silence:** tgcalls (TgVoipWebrtc) reports only the far side's audio level, so `OLSilenceWatchdog` watches inbound audio (8 s while connected and not remote-muted) and logs a crumb; there is no outbound level to watch without changing tgcalls.

CI (`.github/workflows/ios.yml`) runs `ci/clean-slate.sh`, then the OLCall unit tests on a simulator, then unsigned app builds for the simulator and a device, then `ci/dup-classes.sh`. The run fails if any step fails.
