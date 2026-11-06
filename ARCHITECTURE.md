# Open Lounge iOS — Architecture rules

## Audio session ownership (permanent, machine-enforced)

`modules/openlounge-calls/ios/OLAudioSessionOwner.swift` is the **only** file allowed to touch `AVAudioSession`
directly. This is the Linphone-spec single owner: one path, set before media, activated by CallKit `didActivate`.

- Category/mode (`playAndRecord` + `voiceChat`), preferred sample rate / IO buffer, route overrides, preferred input,
  and the one mediaServicesWereReset reactivation all live in `OLAudioSessionOwner`.
- Everything else (OLCallManager, PJSIPEngine, video, UI, React Native, WebView) reads or changes the session **only**
  through `OLAudioSessionOwner.shared` (`currentRoute`, `availableInputs`, `applyRoute`, `applyUserRoute`, holder push/pop).
- Never call `setActive` anywhere else: CallKit activates the session and reports it via `provider(_:didActivate:)`.
- Every `AVCaptureSession` must set `automaticallyConfiguresApplicationAudioSession = false` (video never reopens audio).
- No WebAudio / `<audio>` / WebView audio in the call path.

### Enforcement — `scripts/check-audio-session-owner.sh`
Fails (exit 1) if any `.swift/.m/.mm/.h/.c/.cpp` file other than `OLAudioSessionOwner.swift` contains
`AVAudioSession.sharedInstance`, `[AVAudioSession sharedInstance]`, `setActive`, `setCategory`, `setMode`,
`overrideOutputAudioPort`, `setPreferred*`, `setInputGain`, data-source setters, `requestRecordPermission`,
`setAggregatedIOPreference`, or `automaticallyConfiguresApplicationAudioSession = true`; or if an `AVCaptureSession` file
lacks `automaticallyConfiguresApplicationAudioSession = false`. Comment-only lines are ignored. It has no skip flag,
env override, or allowlist besides the owner file.

It runs, as a hard step:
- `.github/workflows/ios-audio-session-gate.yml` — every push and every pull request, all branches (make it a
  required status check in branch protection);
- every job of `.github/workflows/ios-xcframework.yml` (app, simulator-matrix, adhoc IPA) and `ios-adhoc-local.yml`;
- every EAS build, local or cloud, via the `eas-build-pre-install` npm script.

Run locally: `npm run check:audio-session`.
