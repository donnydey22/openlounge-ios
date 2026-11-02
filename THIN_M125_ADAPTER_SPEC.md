# Thin m125 Mediasoup Adapter Specification

**Status:** Draft implementation contract for Open Lounge iOS build 75
**Scope:** Android-to-iPhone incoming **audio** calls only
**Owner:** Open Lounge iOS native-media workstream

## 1. Objective

Deliver one vendored iOS framework, named `OLMediasoupAdapter.xcframework`, that exposes mediasoup Device, send/receive transport, Opus producer, and Opus consumer operations to Open Lounge native Swift code while using **only the official `StreamWebRTC` 125.6422.070 framework already loaded by `@stream-io/react-native-webrtc` 125.4.5**.

The adapter is a media primitive, not a signaling client. `OpenLoungeCalls` owns the native raw-WSS session, CallKit lifecycle, call authorization, server request/reply framing, telemetry, and terminal teardown. The adapter owns only the internal mediasoup/libwebrtc objects for its one incoming call session.

## 2. Non-negotiable compatibility rules

1. The final application process contains exactly one WebRTC implementation: CocoaPods `StreamWebRTC` `125.6422.070`.
2. The adapter dynamically links to `@rpath/WebRTC.framework/WebRTC` supplied by that pod. It must not embed, vendor, re-export, or statically merge `WebRTC.framework`, `libwebrtc.a`, `libwebrtc-full.a`, Chromium libc++, or any other WebRTC object archive.
3. The adapter must not define an Objective-C class named `RTC*`, nor contain a defined `_OBJC_CLASS_$_RTC*` or `_OBJC_METACLASS_$_RTC*` symbol. Undefined references to classes provided by the official framework are permitted.
4. The adapter must not use the rejected `Mediasoup.xcframework` release `m125-stream-125.6422.070-run41370196047`; that artifact embeds a second WebRTC runtime and is unsuitable for co-installation.
5. The adapter public Swift API must not expose `RTC*`, C++ WebRTC, libmediasoupclient, raw pointer, or `Unmanaged` types. Any `RTC*` instances stay private inside the adapter.
6. The adapter must never call `AVAudioSession.setActive`, change AVAudioSession category/mode/route, configure a competing audio session, or invoke WebKit. `OLCallManager` and `OLNativeAudio` remain the CallKit audio-session authority.
7. There is no JavaScript, WebView, Socket.IO, page relay, or fallback media lane in the incoming path. Failure is terminal and visible.

## 3. Required supplier inputs

The adapter build is rejected unless all inputs are supplied together and immutable:

- The official Stream `WebRTC.xcframework.zip` for `StreamWebRTC` `125.6422.070`, including its SHA-256. The current app keeps using the Pod framework; the archive is a build-time compatibility input only.
- The exact WebRTC source revision, full C++ header bundle, generated build headers, and GN arguments that produced that official Stream framework. Version labels or a moving branch name are insufficient.
- The selected `libmediasoupclient` source revision and complete patch series, including every source dependency such as `libsdptransform`.
- A macOS/Xcode reproducible build manifest: Xcode version, SDK, deployment target, compiler flags, build commands, architecture list, and artifact checksums.
- Complete licensing/SBOM material: Stream/WebRTC license aggregation, WebRTC `LICENSE`/`NOTICE`/`PATENTS`, libmediasoupclient ISC notice, mediasoup-client-swift MIT notice, sdptransform license, and all transitive notices.

The previously supplied release establishes useful m125 source lineage, but it does not satisfy this input gate because its wrapper embeds a separate WebRTC runtime and its WebRTC binary is not byte-identical to the official Stream Pod binary.

## 4. Framework layout and Pod integration

### 4.1 Required deliverable layout

```text
OLMediasoupAdapter.xcframework/
  ios-arm64/OLMediasoupAdapter.framework/
  ios-arm64_x86_64-simulator/OLMediasoupAdapter.framework/
  Info.plist
OLMediasoupAdapter.podspec
SHA256SUMS
provenance.json
link-audits/
  device-arm64.txt
  simulator-arm64.txt
  simulator-x86_64.txt
licenses/
  ... complete third-party notices ...
```

The minimum deployment target is iOS 13.0, matching the current Stream Pod. If a source dependency requires a higher deployment target, the supplier must state it explicitly and Open Lounge must approve the support change before integration.

### 4.2 Podspec contract

The internal pod must vendor only `OLMediasoupAdapter.xcframework` and depend on the exact existing pod:

```ruby
s.name = 'OLMediasoupAdapter'
s.version = '0.1.0-m125'
s.platform = :ios, '13.0'
s.vendored_frameworks = 'OLMediasoupAdapter.xcframework'
s.dependency 'StreamWebRTC', '= 125.6422.070'
s.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreAudio', 'CoreMedia', 'CoreVideo',
               'VideoToolbox', 'Foundation', 'Network'
s.libraries = 'c++'
```

The pod must not declare or vendor `WebRTC`, `StreamWebRTC`, `Mediasoup`, `mediasoupclient`, `sdptransform`, `libwebrtc`, `libwebrtc-full`, or another framework whose binary contains WebRTC objects. The final Pod install must embed and sign `WebRTC.framework` exactly once.

The adapter may statically merge libmediasoupclient and sdptransform object code into its own binary **only** when those objects link against the existing official dynamic `WebRTC.framework` and do not introduce bundled WebRTC, Chromium libc++, or duplicate Objective-C runtime classes.

## 5. Build and link contract

### 5.1 Thin linkage proof before implementation

Before building the Swift wrapper, perform a minimal m125 link probe:

1. Compile a tiny libmediasoupclient object against the immutable official-compatible headers.
2. Link it only against the official `WebRTC.framework` and the Apple system frameworks.
3. Build device arm64 and simulator arm64/x86_64 outputs.
4. Run the probe on an iOS simulator and a physical device with the official Stream Pod present.

The probe must prove that every required WebRTC symbol is exported/resolved by the official framework. If the official framework hides a required C++ symbol, fails to link, or crashes during Device creation, this specification fails closed. The remedy is a Stream-supported thin adapter/extension or explicit Stream framework support—not adding a static WebRTC archive or substituting a custom WebRTC binary.

### 5.2 Required build properties

- Use the exact source/header/configuration tuple defined in Section 3.
- Use the official framework as the only WebRTC linker input. Do not use `-force_load`, `-all_load`, or any linker setting that pulls in a second WebRTC runtime.
- Keep C++ code private to the framework. The app target imports only `OLMediasoupAdapter`.
- Treat warnings as errors for duplicate symbols, undefined WebRTC symbols, non-modular headers, and public API leakage of `RTC*` types.
- Use a unique bundle identifier and module name: `com.donnydey.openlounge.mediasoupadapter` and `OLMediasoupAdapter`.

## 6. Public Swift API

The adapter exposes JSON-compatible transport boundaries and opaque Swift session ownership. It does not expose RTC objects.

```swift
public struct OLMTransportParameters: Sendable {
  public let id: String
  public let iceParametersJSON: String
  public let iceCandidatesJSON: String
  public let dtlsParametersJSON: String
  public let sctpParametersJSON: String?
  public let iceServersJSON: String?
}

public struct OLMConsumerParameters: Sendable {
  public let id: String
  public let producerId: String
  public let kind: String       // audio only for build 75
  public let rtpParametersJSON: String
}

public enum OLMAdapterEvent: Sendable {
  case transportState(direction: String, state: String)
  case firstOutboundAudioPacket
  case firstInboundAudioPacket
  case failed(stage: String, code: String)
}

public protocol OLMAdapterSignaling: AnyObject {
  func connectTransport(direction: String, transportId: String, dtlsParametersJSON: String,
                        completion: @escaping (Result<Void, Error>) -> Void)
  func createProducer(transportId: String, kind: String, rtpParametersJSON: String,
                      appDataJSON: String, completion: @escaping (Result<String, Error>) -> Void)
}

public final class OLMIncomingAudioSession {
  public init(eventSink: @escaping @Sendable (OLMAdapterEvent) -> Void)
  public func loadDevice(routerCapabilitiesJSON: String) throws
  public func createTransports(send: OLMTransportParameters, receive: OLMTransportParameters,
                               signaling: OLMAdapterSignaling) throws
  public func startAudioAfterCallKitActivation() throws
  public func consume(_ consumers: [OLMConsumerParameters]) throws -> [String]
  public func resumeConsumer(id: String)
  public func stop(reason: String)
}
```

This is an API contract, not a requirement to use precisely these type names. Any variation must preserve these constraints:

- All request material is string JSON or Foundation data validated by Open Lounge before entering the adapter.
- The adapter provides asynchronous connect/produce completion hooks. It must not force the caller to synchronously block a WebSocket thread while libmediasoupclient waits for DTLS/producer completion.
- `startAudioAfterCallKitActivation()` is the only method allowed to create/open the microphone track or begin production. It must fail if called before the CallKit activation latch.
- Only Opus, 48 kHz, mono audio is allowed for this build. Video, data channels, camera capture, and screen sharing are rejected.
- `stop(reason:)` is idempotent, closes consumers then producers then transports, releases private tracks/factory state, and cannot issue callbacks after terminal completion.

## 7. Threading and lifetime rules

`OLMIncomingAudioSession` owns one serial executor/dispatch queue for all libmediasoupclient and internal WebRTC objects. All public methods enqueue to that executor; transport delegates and internal callbacks must immediately hop back to it before touching session state.

The session uses a monotonic generation and terminal latch. A callback from an old CallKit activation, stale WebSocket request, or closed transport may log a redacted diagnostic but cannot mutate a new call. The adapter uses ARC/Swift ownership only at its public boundary. It must not expose manual `malloc`/`free`, `Unmanaged`, raw C pointers, or C API ownership to Open Lounge code.

No adapter object may be shared with `@stream-io/react-native-webrtc`. The official WebRTC framework is shared, but tracks, peer connections, factories, sessions, and audio objects created for the native incoming lane remain private to the adapter. This prevents lifetime and thread ownership errors even though the process has one WebRTC framework.

## 8. Open Lounge coordinator contract

`OLIncomingMediaCoordinator`, inside `OpenLoungeCalls`, must use the adapter as follows:

1. After a successful canonical PushKit/CallKit report, it may asynchronously authenticate raw WSS, call `call:ack`, accept cached router capabilities, and load the Device. It does not capture, produce, consume, or activate audio.
2. `CXAnswerCallAction` records answer intent only. `provider(_:didActivate:)` is the only call site allowed to invoke `call:accept`, `ms:join`, transport setup, and `startAudioAfterCallKitActivation()`.
3. The coordinator owns the raw `wss://…/ws` request envelope and directly sends `session:resume`, `call:ack`, `call:accept`, `ms:join`, `ms:transport:create`, `ms:transport:connect`, `ms:produce`, `ms:consume`, `ms:consumer:resume`, and `ms:leave`. It never sends the gateway secret.
4. The coordinator maps adapter connect/produce hooks to raw WSS replies and validates call ID, native connection ID, direction, transport ID, and JSON fields before forwarding them.
5. All terminal sources—CallKit end/reset/timeout, report failure, expiration, decline, remote end, WSS failure, and media failure—use one idempotent terminal method that stops the adapter and sends `ms:leave` only when a session was joined.
6. JavaScript receives UI state only. It may display incoming, connecting, connected, failed, and ended state; it cannot control media, relay native `ms:*` requests, supply DTLS, capture a microphone, resume WebKit audio, or create a fallback transport.

## 9. Mandatory binary and runtime audits

Every release must include the command output for all three architectures:

```bash
# No defined RTC Objective-C classes in the adapter.
nm -m OLMediasoupAdapter.framework/OLMediasoupAdapter | \
  grep -E 'external (defined|weak) .*_OBJC_(META)?CLASS_\$_RTC' && exit 1 || true

# No embedded WebRTC/static archive payload, and exactly one dynamic dependency.
otool -L OLMediasoupAdapter.framework/OLMediasoupAdapter
find OLMediasoupAdapter.xcframework -iname '*webrtc*' -o -iname '*libc++*'

# Final application archive must embed one WebRTC framework only.
find OpenLounge.app/Frameworks -maxdepth 1 -iname '*WebRTC*.framework' -print
```

The audited adapter load commands may reference `@rpath/WebRTC.framework/WebRTC` once. They must not reference a custom WebRTC path. The final IPA must have exactly one `WebRTC.framework`; its SHA-256 must match the official Stream Pod artifact recorded for the build.

Runtime tests must run with duplicate-class diagnostics enabled where supported and show no `Class RTC… is implemented in both …` output. They must create and close Device/send/receive transport objects repeatedly on device and simulator without leaked audio session ownership, duplicate classes, or stale callbacks.

## 10. Acceptance matrix

| Gate | Required proof | Result required before merge |
|---|---|---|
| Official binary identity | Official Stream zip/framework checksum recorded and matches the app Pod | Pass |
| Source/header compatibility | Immutable source/header/GN manifest for the official binary | Pass |
| Link probe | Adapter links against official Stream framework without static WebRTC | Pass on device and simulator |
| Symbol audit | No defined `RTC*` Objective-C symbols or bundled WebRTC/libc++ | Pass for all slices |
| Dynamic dependency audit | One `@rpath/WebRTC.framework/WebRTC` dependency; no custom WebRTC | Pass |
| Pod integration | One embedded official WebRTC framework in generated app | Pass |
| Public API isolation | No public WebRTC/C++/pointer types | Pass |
| CallKit lifecycle | No capture before `didActivate`; no manual AVAudioSession activation | Pass |
| Signaling ownership | Native raw-WSS only; no WebView `ms:*` relay | Pass |
| Audio media | Opus 48 kHz mono producer/consumer; UDP-first behavior retained | Pass |
| Device validation | Pixel 10 Android caller → iPhone native incoming audio works foreground, locked/background, UDP and TURN fallback | Pass |
| Timing | Measured answer-to-bidirectional-audio target under 500 ms on a good connection | Measured result required |

## 11. Explicit failure conditions

Stop and report failure without a fallback if any of the following occurs:

- The official Stream framework does not export the symbols needed by a thin libmediasoupclient link.
- The adapter needs a static WebRTC archive, a custom WebRTC framework, or duplicate `RTC*` classes to build.
- The immutable Stream source/header provenance cannot be supplied.
- The adapter’s public API leaks WebRTC objects or its lifecycle attempts manual AVAudioSession activation.
- The final app embeds more than one WebRTC framework or logs duplicate `RTC*` classes at runtime.
- The native WSS/media lane requires JavaScript/WebKit to relay media control or recover audio.

A failed gate must leave the existing validated Part 1 CallKit/PushKit ownership intact and present an explicit native-media failure state. It must not silently use the old JavaScript mediasoup path.
