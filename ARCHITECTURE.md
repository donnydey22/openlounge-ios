# Open Lounge iOS — Architecture rules

## Audio session ownership (permanent, machine-enforced)

Exactly **two** files may touch `AVAudioSession` directly, each in its own scope (updated 2026-11-10, olcall):

1. **During olcall calls** — `modules/openlounge-olcall/ios/tgcalls-swift/OLCallAudioDevice.swift` (tgcalls' custom ADM,
   Telegram `SharedCallAudioDevice`). It configures the session (`PlayAndRecord`/`VoiceChat`) via
   `prepareSessionForCallKit()` before the CallKit start/answer action is fulfilled, starts the ADM only after CallKit
   `didActivate` (forwarded by OLCallManager), and owns route/speaker, interruptions and media-services reset for the call.
2. **Outside calls** — `modules/openlounge-calls/ios/OLAudioSessionOwner.swift` (rooms, voice notes, ambient; holder
   stack call > room > voice note > ambient). Every function in it that mutates the session starts with
   `guard !olcallOwnsSession` (true while a call holder is pushed), so it never touches the session during a call.

- Everything else (OLCallManager, video, UI, React Native, WebView) changes the session only through those two:
  in a call via `OLCall.setSpeaker` / `callKitDidActivate`; outside via `OLAudioSessionOwner.shared`
  (`currentRoute`, `availableInputs`, `applyRoute`, `applyUserRoute`, holder push/pop).
- Never call `setActive` anywhere else: CallKit activates the session and reports it via `provider(_:didActivate:)`.
- Every `AVCaptureSession` must set `automaticallyConfiguresApplicationAudioSession = false` (video never reopens audio).
- No WebAudio / `<audio>` / WebView audio in the call path. One media engine: the old WebRTC.xcframework path
  (`import WebRTC`, `RTCAudioSession`) is removed and forbidden.

### Enforcement — `scripts/check-audio-session-owner.sh`
Fails (exit 1) if any `.swift/.m/.mm/.h/.c/.cpp` file other than those two contains
`AVAudioSession.sharedInstance`, `[AVAudioSession sharedInstance]`, `setActive`, `setCategory`, `setMode`,
`overrideOutputAudioPort`, `setPreferred*`, `setInputGain`, data-source setters, `requestRecordPermission`,
`setAggregatedIOPreference`, or `automaticallyConfiguresApplicationAudioSession = true`; if any function in
`OLAudioSessionOwner.swift` that mutates the session lacks `guard !olcallOwnsSession`; if `import WebRTC` /
`RTCAudioSession` reappears in `modules/`; or if an `AVCaptureSession` file lacks
`automaticallyConfiguresApplicationAudioSession = false`. Comment-only lines are ignored. Only Telegram's unpacked
`TgVoipWebrtc.xcframework` (prebuilt binary + headers, never committed) is excluded. No skip flag, env override, or
other allowlist.

It runs, as a hard step:
- `.github/workflows/ios-audio-session-gate.yml` — every push and every pull request, all branches (make it a
  required status check in branch protection);
- `.github/workflows/ol-olcall-ios-app.yml` (required step) and `ios-adhoc-local.yml`;
- every EAS build, local or cloud, via the `eas-build-pre-install` npm script.

Run locally: `npm run check:audio-session`.
