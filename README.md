# Open Lounge iOS: calling

One-to-one audio and video calls on the Open Lounge Pion engine, relayed over TURN. One codebase, one path.

```
tap -> permission gate -> backend call control (start / accept -> CallMedia {url, token})
    -> OLTgcallsEngine: wss://turn.openlounge.app/v1/call  join {token} -> joined {key, isOutgoing, iceServers}
    -> OLTgcallsInstance (tgcalls, TgVoipWebrtc.xcframework), relay only through coturn TURN
```

| iOS | Android twin |
|---|---|
| `OLCall/Sources/OLCall/OLTgcallsEngine.swift` | `OlTgcallsEngine.kt` |
| `OLCall/Sources/OLCallCore/OLCallStates.swift` | `OlCallStates.kt` |
| `OLCall/Sources/OLCallCore/OLRtcServers.swift` | `OlRtcServers.kt` |
| `OLCall/Sources/OLCallCore/OLVersions.swift` | `OlVersions.kt` |
| `OLCall/Sources/OLCall/OLBreadcrumbs.swift` | `OlBreadcrumbs.kt` |
| `OLCall/Sources/OLCallCore/OLCallMedia.swift` | app-side CallMedia check |
| `App/CallController.swift` | app-side call class |

- **Audio session:** `OLCallAudioDevice` is the only owner of `AVAudioSession`. Nothing else configures or activates it.
- **State log:** `olcall state <from> -> <to> reason=<r> t=<ms> call=<id>` over idle, joining, offering, answering, connected and failed, with the same reason tags as Android.
- **Permissions:** nothing at launch. An audio call asks for the microphone. A video call asks for the camera and the microphone in one flow. Turning video on mid-call asks for the camera only. A denial ends that call or that toggle silently, with no re-prompt.
- **UI:** the call screen layout, design tokens, squircle and avatar come from the first Open Lounge call UI in this repository's history: `d6135f0` (2026-11-04, call screen), `9c851a0` (2026-11-04, squircle avatar) and `325110e` (2026-10-14, incoming card).

CI (`.github/workflows/ios.yml`) runs `ci/clean-slate.sh`, then the OLCall unit tests on a simulator, then unsigned app builds for the simulator and a device, then `ci/dup-classes.sh`. The run fails if any step fails.
