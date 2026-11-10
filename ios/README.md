# iOS: Open Lounge calls on tgcalls ↔ olcall (Go/Pion)

Phones only. Pipeline: OL app (Expo/React Native) → Expo module `OpenLoungeOlcall` (Swift) → **Telegram-iOS's production call wrapper `OngoingCallThreadLocalContextWebrtc`** (TgVoipWebrtc: tgcalls + vendored WebRTC + iOS ADM + camera + video views) → ICE/DTLS-SRTP over UDP → olcall Go/Pion server → the other phone (Android or iPhone).

NTgCalls has no iOS build, and the tgcalls `Package.swift` is macOS-only. The Telegram-iOS Bazel tree is the only iOS path, so everything here builds from it.

**Engine layer (2026-11-09):** `OLTgcallsSwift/` is the thin Swift wrapper over raw tgcalls: a SwiftPM package (`OLCall`, `OLTgcallsCall`, `OLCallAudioDevice`, `OLSignalingRelay`), with its build in `build.sh` and its rationale in `DARWIN-DECISIONS.md`. `OpenLoungeCalls/OLCallSession.swift` is now only a UI-state adapter over it.

## What is here
| Path | What |
|---|---|
| `OpenLoungeCalls/Sources/OLCallSession.swift` | One call: WebSocket to `/v1/call`, `OngoingCallThreadLocalContextWebrtc` with **allowP2P=true, no reflectors, VP8 preferred** (the proven config), mute / camera / switch / speaker / hang up, `UiState` for the screen |
| `OpenLoungeCalls/Sources/OLCallQueue.swift` | The serial-queue adapter the wrapper requires |
| `OpenLoungeCalls/Sources/OpenLoungeOlcallModule.swift` | Expo module + `<OlcallVideoView source="remote"\|"local">` |
| `OpenLoungeCalls/js/olcall.ts` | JS API for the existing call screen |
| `OpenLoungeCalls/OpenLoungeOlcall.podspec`, `expo-module.config.json`, `modules/*/module.modulemap` | Pod vendoring `TgVoipWebrtc.xcframework`; C module for the audio-session policy |
| `../audio/ios/OLAudioSessionController.swift` | AVAudioSession ownership through the tested C policy (`audio/core/ol_session_policy.c`) → `setManualAudioSessionIsActive` |
| `OLTgVoipXCFramework/BUILD.bazel` | `apple_static_xcframework` of `//submodules/TgVoipWebrtc:TgVoipWebrtc` (device arm64 + simulator arm64, iOS 15.0) |
| `OLTgPeerTest/` | Minimal proof app: one real call against olcall, which writes blob captures (`Documents/olpeer-*.blobs.jsonl`) |
| `install-into-telegram-ios.sh` | Installs OLTgPeerTest + OLTgVoipXCFramework into a Telegram-iOS checkout. It appends `exports_files` for TgVoipWebrtc PublicHeaders to that checkout's BUILD |
| `install-into-ol-app.sh` | Adds `modules/openlounge-olcall/` to a clone of the OL app and refuses if any tracked file changed |
| `../ci/github/workflows/oltgpeertest-ios.yml` | Cloud-Mac workflow file (not installed, not triggered) |

## Where it plugs in
- **Repo:** `pj-openlounge-ios` (Expo / React Native). UI baseline iOS native `7aaac81` (avatar + squircle call UI restored). The existing native calls module is `modules/openlounge-calls`. `OpenLoungeOlcall` is added next to it as `modules/openlounge-olcall`, and nothing existing is modified.
- **Swap:** in the existing call screen component, replace the media calls (the current engine's start / mute / camera / hang up) with `olcall.*`, and render `OlcallVideoView` inside the existing layout. The avatar squircle, name, timer and control buttons stay as they are.
- **Signaling:** the existing OL WS `call:*` flow stays. The `olcall: {url, token}` from `call:accept` (`backend/olcallToken.ts`) is what `olcall.start` takes.

## Wire the call screen (the one manual step)
```tsx
import * as olcall from '../../modules/openlounge-olcall/js/olcall';

useEffect(() => {
  const sub = olcall.addCallStateListener(setCall);          // drives the EXISTING UI
  olcall.start({ url: accept.olcall.url, token: accept.olcall.token, video: isVideoCall,
                 peer: { userId: peer.id, displayName: peer.name, avatarUrl: peer.avatarUrl } });
  return () => { sub.remove(); olcall.hangup(); };
}, []);

// existing layout, unchanged styling:
{call?.remoteVideoOn
  ? <olcall.OlcallVideoView source="remote" style={StyleSheet.absoluteFill} />
  : <ExistingAvatarSquircle uri={peer.avatarUrl} />}
{call?.cameraOn && <ExistingSelfSquircle><olcall.OlcallVideoView source="local" style={StyleSheet.absoluteFill} /></ExistingSelfSquircle>}
<ExistingTimer text={call?.phase === 'inCall' ? olcall.formatElapsed(call.elapsedSec) : 'Connecting…'} />
// buttons -> olcall.setMuted / setCameraEnabled / switchCamera / setSpeaker / hangup
```
`Info.plist` needs `NSMicrophoneUsageDescription` and `NSCameraUsageDescription`; keep the app's existing strings if it has them. To use CallKit, set `usesCallKit: true` in `OLCallSession` and forward `provider(_:didActivate:)` / `didDeactivate` to it.

## Build (macOS + Xcode 27.1 per the pin; cloud Mac or local)
```
ios/install-into-telegram-ios.sh <Telegram-iOS@24638bc> org.openlounge.oltgpeertest
cd <Telegram-iOS> && python3 build-system/Make/Make.py --overrideXcodeVersion build \
  --configurationPath=build-system/template_minimal_development_configuration.json \
  --codesigningInformationPath=build-system/fake-codesigning --disableProvisioningProfiles \
  --configuration=release_arm64 --buildNumber=1 --target=//OLTgVoipXCFramework:TgVoipWebrtc
ios/install-into-ol-app.sh <ol-ios-clone> <Telegram-iOS>/bazel-bin/OLTgVoipXCFramework/TgVoipWebrtc.xcframework
cd <ol-ios-clone> && npx expo prebuild --platform ios && (cd ios && pod install) && <existing EAS/Xcode build>
```

## Status
**Nothing on iOS has been compiled.** The build host is Linux and the cloud-Mac workflow has not been triggered. **iOS↔Pion is UNPROVEN** until (1) the CI simulator build passes, and (2) one real iPhone call through olcall reaches Established, with far-side audio and decoded video.
