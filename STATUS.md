# native-call-ui (iOS) — status
Done. IPA 0.3.19 (98), ad hoc via CI run 41953888929 (pjsip-ios-xcframework, adhoc job), live on openlounge.app/download.
SHA-256 6e6c2713f9ef49232913dae4ae63a76836a1c86fecede6650d373a9e1bda7cbe. b95 stays as the archived rollback asset.
- src/NativeCallScreen.tsx: native screen for 1:1 voice calls. Look = Open Lounge web call screen; flow/placement per
  Telegram-iOS@279f89e PresentationCall.swift, CallControllerNode.swift, CallControllerButtonsNode.swift.
- Gate: takesOver() = audio calls with a callId only; video calls and everything else stay on the web call screen.
- Tests: tests/nativeCallFlow.test.ts 5/5; tsc clean. Not done: on-device native-to-web call (no device here).
