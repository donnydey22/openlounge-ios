# Open Lounge iOS 75: Native incoming audio calls

**Base:** iOS build 74, commit `52688e6`
**Branch:** `manus/ios75-native-callkit-mediasoup`
**Scope:** incoming Android-to-iPhone **audio** calls only. Outgoing calling, video, rooms/LiveKit, Android behavior, non-call server endpoints, mediasoup UDP preference, and the existing TURN fallback order are preserved.

## Constraints carried into this build

The signaling path is raw TLS WebSocket JSON frames, never Socket.IO. Media preference remains mediasoup SFU over UDP, followed by Coturn UDP/3478, TCP/3478, then TURNS/443. The iOS hot path is native: PushKit reporting, CallKit answer handling, `didActivate`, mediasoup Device/transport/Opus producer-consumer work, and teardown must not depend on JavaScript. JavaScript receives asynchronous state for UI only.

The existing b74 source has one app-owned `PKPushRegistry` and one app-owned `CXProvider` in `OLCallManager`, but it does **not** contain `expo-callkit-telecom` or its `CallSession` type. The package named in the brief has been independently inspected at v1.0.1. It creates another registry and provider, so it cannot be added unchanged.

## Part 1 — Single-owner telecom core

### Chosen design

Build a local, source-controlled fork/extension of `expo-callkit-telecom` v1.0.1 inside the existing `OpenLoungeCalls` Expo module. The fork retains its `CallSession` model and becomes the sole owner of exactly one `PKPushRegistry` and exactly one `CXProvider`.

`OLCallManager` becomes an adapter around that core. It keeps the existing JS-facing `OpenLoungeCalls` events and preserves the outgoing call sequence, but it must no longer construct a provider or PushKit registry. The core routes an incoming CallKit session to the native incoming-call coordinator and routes legacy outgoing actions to the current outgoing handlers.

The fork must preserve the package MIT notice. It is an extension of the inspected v1.0.1 source, not a second independently registered package.

### Canonical incoming session

The server `callId` is the canonical dedupe key. The core stores one `CallSession` and one CallKit UUID per live `callId`, with `reporting`, `reported`, `answered`, and terminal states. It resolves the three possible ingress orders without creating another report:

1. PushKit followed by a duplicate PushKit delivery.
2. The authenticated page/WS fallback followed by PushKit.
3. PushKit followed by the page/WS fallback.

Every VoIP push completion handler still completes. A duplicate updates safe display metadata only; it never calls `reportNewIncomingCall` a second time. A short-lived persisted mapping is used only while the call is live so an app relaunch cannot generate a second CallKit UUID for a still-ringing call.

### CallKit and audio rules

The core configures the provider before reporting the first incoming call. Its `CXProviderConfiguration` carries the ringtone; `audio` and `voip` background modes remain declared. Objects required by PushKit/CallKit are created during launch to avoid the post-unlock race.

A system answer and the in-app fallback both request the **same** `CXAnswerCallAction` for the canonical UUID. The provider delegate is the only place that fulfills or fails the action. It records every provider callback to `[OLCalls]` and client-diag with UUID, `ms` since signaling, and a redacted session snapshot.

The answer action does not turn audio on. `didActivate` is the sole activation boundary for incoming media. Incoming code does not call `AVAudioSession.setActive`, configure a competing WebView session, or use WebView audio. Existing b74 audio reset runs before each ring and on every terminal path. A late prior-call deactivation cannot alter the next call.

The 2-second reporting watchdog logs loudly and emits a visible in-app fallback card. That card sends the same canonical `CXAnswerCallAction`; it is never a direct media answer or a second incoming-call report. Failed reporting, missing credentials, transport failure, or native-media incompatibility is surfaced as a native terminal failure, never as a silent JavaScript fallback.

Outgoing calls retain the current `CXStartCallAction → startedConnecting → connected` behavior. They are not routed through incoming dedupe or incoming native media.

## Part 2 — Native Swift mediasoup lane

### Client decision

Neither requested client can be used unchanged with Stream WebRTC m125 (`StreamWebRTC` `125.6422.070`, React Native package `125.4.5`):

- `VLprojects/mediasoup-client-swift` is the chosen *source baseline* because it is a maintained Swift wrapper and exposes Device, send/receive transport, producer, and consumer APIs. Its published binary, however, pairs a patched libmediasoupclient with its own m140 WebRTC XCFramework.
- `ethand91/mediasoup-ios-client` is rejected. It is an older Objective-C wrapper with m79/m84-era WebRTC assumptions and an obsolete binary distribution.

The required implementation is a source-controlled fork of the VLprojects wrapper plus libmediasoupclient compiled against the **exact same Stream m125 WebRTC source, patch set, GN arguments, visibility, C++ library, and architectures** as the app’s `StreamWebRTC`. Its m140 binary is forbidden. The final app must contain exactly one WebRTC implementation.

### Mandatory build gate — verified release result

The supplied release `m125-stream-125.6422.070-run41370196047` was downloaded and verified against its published `SHA256SUMS`; GitHub SLSA verification also passed for `Mediasoup.xcframework.zip`. It supplies an m125 wrapper and the three required iOS architecture families, but it does **not** satisfy the app integration gate.

`Mediasoup.framework` contains a static full WebRTC copy while also dynamically loading `@rpath/WebRTC.framework/WebRTC`. The existing app already loads Stream’s official `StreamWebRTC` `125.6422.070` pod, whose import module is also `WebRTC`. Binary review found duplicate `RTC*` Objective-C definitions (including `RTCPeerConnectionFactory`, `RTCPeerConnection`, and `RTCAudioSession`) in the two framework images. Objective-C class registration is process-wide, so isolating wrapper calls to the native incoming path cannot make this safe. The custom release’s WebRTC byte hashes also differ from Stream’s published framework; its documented source relation is lineage, not a byte-identical reproduction.

The release is therefore **rejected for co-installation**. This branch must not choose the release note’s “native lane only” option, add its `Mediasoup.framework` to the app target, replace `StreamWebRTC` with the custom WebRTC, link a second WebRTC framework, or retain the JavaScript mediasoup path as an invisible fallback.

The remaining acceptable input is a thin, source-verified m125 adapter that links only to the existing official `StreamWebRTC` `125.6422.070` framework and contains no static `libwebrtc-full.a` or defined `RTC*` Objective-C classes. Its supplier must prove that with a link map/`nm` audit for all device and simulator slices, provide a compatibility build against the Stream pod, and include all required third-party notices. Only then can this branch implement and device-validate the native mediasoup lane.

### Native call flow after the gate passes

1. At launch, create the telecom core and native media coordinator. When a valid native access token is available, preconnect the raw `wss://…/ws` session and prewarm router RTP capabilities, Device, cached ICE candidates, and a liveness-checked warm transport reservation.
2. On a VoIP push, the core reports the canonical CallSession in the same PushKit run loop. It starts only non-blocking preparation; no synchronous disk or network request runs on the answer action.
3. The canonical `CXAnswerCallAction` records the answer intent. On `didActivate`, the coordinator starts only the prepared native media work.
4. The coordinator uses a native TLS WebSocket client and the existing raw request/reply frames: `session:resume`, `call:accept`, `ms:join`, transport creation/connect, producer creation, consumer creation/resume, and terminal leave. JavaScript does not relay DTLS, producer, consumer, or transport operations.
5. The native client verifies Opus/48 kHz support before producing the `RTCAudioTrack`. It creates paired send/recv transports, produces the microphone, consumes remote Opus, and reports `transport connected`, first inbound packet, and first outbound packet.
6. ICE gathering begins early, is cached, and never blocks the answer. The existing UDP-first/TURN fallback policy is preserved. The coordinator logs the selected mechanism and does not add direct SFU TCP.
7. Native code owns interruption recovery. The WebRTC interruption handler is disabled only if the exact m125 API supports that setting; otherwise the build fails the gate rather than guessing a private API. The coordinator processes interruptions manually and never lets WebKit audio compete for the call session.

## Server payload boundary

The current server payload already supports the incoming path. The only permitted server runtime change is an optional trim in `server/calls/voip.ts`, after a tracked backup, at the APNs serialization boundary only. It retains `type`, `callId`, `callerName`, `video`, `expiresAt`, and `declineToken`; it removes unused `callerPhoto` and `url`, without changing FCM or Android payloads. `declineToken` remains because a cold/expired-session iPhone requires it to decline natively.

## Diagnostics and timing

Every stage records a timestamped `[OLCalls]` and client-diag event:

- Android/server call press
- VoIP push sent and received
- native call screen reported
- answer action
- `didActivate`
- native transport connected
- first outbound audio packet
- first inbound audio packet

The target is under 500 ms from answer to bidirectional audio on a good connection. The timing result is a device-test result, not a claim inferred from code inspection.

## Required tests

The branch must add source-level tests for singleton registration, canonical UUID dedupe across all ingress orders, one-report behavior, cold-start token replay, watchdog/in-app answer action reuse, outgoing-call regression, reset-before-ring/end behavior, audio-only/Opus configuration, raw WSS request framing, and the APNs payload selector if the server trim is implemented.

The final device test remains: “Keiko calls from Pixel 10 audio-only, Donny answers in-app, both hear each other immediately, native call screen visible.” It must cover locked/backgrounded and foreground cases, direct UDP and TURN fallback, interruption/route changes, and the absence of duplicate CallKit reporting.

## Sources evaluated

- `expo-callkit-telecom` v1.0.1 package source, MIT licensed.
- [VLprojects/mediasoup-client-swift](https://github.com/VLprojects/mediasoup-client-swift), MIT licensed source baseline only.
- [ethand91/mediasoup-ios-client](https://github.com/ethand91/mediasoup-ios-client), rejected for outdated WebRTC integration.
- [libmediasoupclient installation guidance](https://mediasoup.org/documentation/v3/libmediasoupclient/installation/), which documents a matched WebRTC/libmediasoupclient build and currently targets m140.
- [Verified wrapper release](https://github.com/donnydey22/stream-webrtc-m125-build/releases/tag/m125-stream-125.6422.070-run41370196047), rejected for co-installation because it embeds a second WebRTC runtime.
