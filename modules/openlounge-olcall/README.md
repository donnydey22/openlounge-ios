# openlounge-olcall (iOS)

Open Lounge 1:1 calls on raw tgcalls (Telegram-iOS TgVoipWebrtc) to the olcall Go/Pion server
(`wss://<host>/v1/call`, TLS by Caddy). Same protocol as Android's `OlTgcallsEngine.kt`:
join {token,...} -> joined {key, isOutgoing, versions, iceServers} -> blob <-> blob -> hangup/bye.

Generated from branch `ol-tgcalls-swift-ios` (single source of truth):
- `ios/tgcalls-swift/*.swift` = `ios/OLTgcallsSwift/Sources/OLTgcalls/*.swift`
- `ios/Sources/`, `ios/OpenLoungeOlcall.podspec` = `ios/OpenLoungeCalls/...` (the JS API `js/olcall.ts` is not installed: routing is native, in OLCallManager)
- `ios/audio/core/` = `audio/core/ol_audio.h`, `ol_session_policy.c`
- `ios/Frameworks/TgVoipWebrtc.xcframework` is NOT committed; CI unpacks it from the
  oltgcalls-swift-ios artifact.

Routing: `modules/openlounge-calls/ios/OLCallManager.swift` uses this engine only when the backend's
CallMedia is `{provider:"olcall", url: ws(s)://.../v1/call, token}` (`OLCallRoute`); anything else keeps
the existing path until both phones are proven on olcall (then the old paths are deleted).
