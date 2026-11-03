# Open Lounge PJSIP rebuild — design + milestones (phase 1, 2026-11-02 MST)

Pinned engine: pjproject **2.17** (tag, commit 5a45745). Branch `pjsip-rebuild` in donnydey22/openlounge, openlounge-ios (from ios-ship-026), openlounge-android (from main). Pre-branch heads recorded in backup-heads-20261102.txt.

## 1. Signaling over existing TLS WebSocket (no SIP server)
pjsua used as media engine only: SDP generated/consumed via pjmedia_sdp + pjmedia_transport_srtp (no SIP transport), or pjsua2 with a custom "WS-SIP" transport. Messages (JSON, existing WS auth):
- `call.invite {callId, from, to, sdp}` — offer SDP, m=audio RTP/SAVP, `a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:<key>` (+ `a=crypto:2 AES_CM_128_HMAC_SHA1_32`), opus/48000/2, m=video H264 (AV1 when both sides advertise HW).
- `call.ringing {callId}`, `call.answer {callId, sdp}` — answer echoes exactly ONE crypto line with the chosen tag/suite (RFC 4568); `call.ice {callId, cand}` (trickle via coturn), `call.end {callId, reason}`, `call.stats {callId, rtpTx, rtpRx, srtpErr}`.
- Server: relays opaque SDP, never parses keys, never logs SDP bodies (keys redacted: `inline:<redacted>`). Adds VoIP push for iOS ring. TURN creds from existing coturn REST secret.
- pjmedia expectations: RTP/SAVP profile, srtp use=MANDATORY (`PJMEDIA_SRTP_MANDATORY`), keying SDES only (DTLS-SRTP disabled), key = base64 30-byte master key+salt; tag in answer must match offer tag.

## 2. Per-platform
- **iOS (Swift)**: pjproject.xcframework (CI macOS-14). CallKit only; Speakerbox: `provider.setConfiguration` before every `reportNewIncomingCall`; never call AVAudioSession.setActive; `pjsua_set_no_snd_dev()` at call setup, `pjsua_set_snd_dev()` in `provider(_:didActivate:)`, `pjsua_set_no_snd_dev()` in didDeactivate. Teardown on every end: hangup, destroy media transports, release snd dev. WebView = UI only (mic/camera permissions removed from WebView config).
- **Android (Kotlin)**: prefab AAR (`pjproject-2.17-prefab.aar`), ABIs arm64-v8a/armeabi-v7a/x86_64, NDK 27.2.12479018, APP_STL c++_shared, 16 KB pages. ConnectionService for ring; same teardown.
- **Web**: WASM Opus (libopus emscripten) + RTP/SRTP packetizer in WASM; getUserMedia for capture only (AudioWorklet), playback via AudioWorklet. Browsers can't send UDP → **ws-rtp relay** on droplet: Node/Go service on wss://relay.openlounge.app, authenticated by call token, maps each WS to a UDP socket, forwards SRTP packets unchanged (end-to-end SRTP, relay can't decrypt). Designed only, not deployed.
- **Video/simulcast**: H.264 via VideoToolbox/MediaCodec, AV1 only if HW encoder; 2-layer simulcast via coturn relay (note: coturn relays, it isn't an SFU — true simulcast for 1:1 = sender sends layers, receiver selects via `call.layer` message; group needs an SFU → decision for Donny).

## 3. Milestones
M1 (this turn) pjproject builds on CI for iOS + Android; SRTP SDES loopback on Linux. M2 iOS Swift wrapper + CallKit wiring. M3 Android Kotlin wrapper. M4 server WS messages (on branch). M5 two-way test Keiko Android → Donny iPhone, locked phone, redial <30 s ×5, pass = both sides RTP rx>0, srtpErr=0, audible. M6 web relay + WASM. M7 cutover.

## 4. Test plan
Unit: SDP crypto offer/answer parsing; CI loopback (`pjsip-srtp-loopback` workflow): two pjsua, `--use-srtp=2 --srtp-keying=0`, tones 440/880 Hz, both recordings RMS>0.05. Device: M5 checklist above.

## 5. Cutover / legacy removal
Done only after M5 passes and with Donny's direct confirmation: remove legacy call code on pjsip-rebuild branches; stop+disable mediasoup/LiveKit on droplet after config backup; coturn kept. (Requests to delete without backup were NOT executed — see report.)

## 6. Spec additions (Donny 11:42 PM)
1. **Keys in SDP only**: SRTP master keys are carried solely in `a=crypto` of the offer/answer (pjmedia transport_srtp SDES, `PJMEDIA_SRTP_KEYING_SDES` only, DTLS-SRTP off). No separate key-exchange message — `call.invite`/`call.answer` SDP is the key exchange. Verified pattern in CI loopback: offer lists 4 suites (AES_256_CM_HMAC_SHA1_80/32, AES_CM_128_HMAC_SHA1_80/32), answer echoes exactly one matching tag.
2. **iOS audio start gate** (Android→iPhone and all CallKit paths): in `provider(_:didActivate:)` assert `AVAudioSession.sharedInstance()` is active (didActivate is the confirmation; additionally check `secondaryAudioShouldBeSilencedHint`/route present), then `pjsua_set_snd_dev()`. Never call `setActive` anywhere. `didDeactivate` → `pjsua_set_no_snd_dev()` + full teardown.
3. **Adaptive jitter buffer (NetEQ-style, no WebRTC)**: NetEQ proper is WebRTC code (tgcalls embeds WebRTC) → forbidden. Use pjmedia_jbuf adaptive: `PJMEDIA_SOUND_BUFFER_COUNT` default, `jb_init=-1` (adaptive), `jb_min_pre=1`, `jb_max_pre=16` (≈320 ms @20 ms ptime), `jb_max=50`, `jb_discard_algo=PJMEDIA_JB_DISCARD_PROGRESSIVE`, Opus in-band FEC + PLC enabled (`PJMEDIA_HAS_OPUS_CODEC`, `no_vad=1`), set identically in pjsua_media_config on Swift and Kotlin wrappers (M2/M3).

## 7. Decisions (relayed 11:46 PM)
- pjproject 2.17 kept. Opus to be added to iOS/Android CI builds (libopus 1.5.x cross-built, `--with-opus`) — next step.
- Simulcast = 1:1 layered send (2 H.264 layers), receiver picks layer via `call.layer` WS message; media relayed by coturn. No SFU.

## 8. mediasoup SFU for simulcast (Donny t4451u, 11:54 PM) — replaces §7 simulcast note
- PJSIP is still the media engine on the phones. mediasoup sits between PJSIP endpoints: **PlainTransport** per endpoint (`comedia: true`, `rtcpMux: true`, `enableSrtp: true`, `srtpCryptoSuite: 'AES_CM_128_HMAC_SHA1_80'`). The phone sends 2 H.264 simulcast layers (distinct SSRCs); mediasoup forwards the right layer per subscriber. Opus audio is forwarded as-is.
- SRTP compatibility: mediasoup PlainTransport supports AES_CM_128_HMAC_SHA1_80/32 and AEAD_AES_128/256_GCM. **It does not support AES_256_CM_HMAC_SHA1_80, which pjmedia offers first.** The phones must therefore restrict `srtp_opt.crypto` to AES_CM_128_HMAC_SHA1_80. The server maps `a=crypto` ⇄ `transport.connect({srtpParameters})` / `transport.srtpParameters`.
- SRTP is hop-by-hop phone⇄SFU, not end-to-end: mediasoup decrypts in order to forward. **Decision for Donny.**
- **Spec conflict:** relay-only ICE vs PlainTransport. A PlainTransport has no ICE, so it is a plain UDP 5-tuple with comedia. The options are (a) phones reach mediasoup via a coturn TURN allocation (PJSIP ICE with relay-only candidates, mediasoup as the peer address), or (b) phones send directly to mediasoup's public UDP port. (a) keeps relay-only but doubles the hop. **Decision for Donny.**
- Live droplet mediasoup is unchanged. All of this is branch-only (server changes go on openlounge `pjsip-rebuild`).
- LiveKit on Railway: never touched (t4450u).

## 9. WASM Browser Path (PERMANENT — Donny t4453u, 11:57 PM)
A separate WASM VoIP stack, **not** PJSIP compiled to WASM:
1. libopus compiled to WASM. Encode and decode happen entirely in WASM.
2. A small custom RTP + SRTP layer in WASM covering packetization, sequencing, and SRTP with SDES keys taken from the SDP `a=crypto` line.
3. Browser WebRTC is used ONLY for getUserMedia mic capture. No WebRTC transport, networking, or audio processing.
4. The phone is the signaling anchor over the existing TLS WebSockets. Media flows browser→phone or browser→SFU directly.
5. It is a parallel implementation to the phone PJSIP stack, with the same Opus, SRTP and signaling protocol. It is a separate codebase because PJSIP's sockets, threading and audio devices don't compile cleanly to WASM.

**Engineering note: transport.** Browsers cannot open raw UDP sockets, so SRTP packets from the browser need a carrier. Candidates:
- (A) a binary WebSocket (wss) to a small ws↔UDP relay on the droplet or in front of the SFU. Works in every browser, but TCP head-of-line blocking adds latency under loss.
- (B) WebTransport (HTTP/3 datagrams) to the droplet/SFU. Unreliable datagrams give UDP-like behavior, but Safari support is recent.
In both cases the SRTP stays encrypted end-to-end through the relay. **This is a decision for Donny.** WebRTC is not substituted.

## 10. Video (Donny t4454u, 12:01 AM)
- **Codecs.** H.264 is the base on every platform. AV1 is used only where the hardware has an AV1 encoder/decoder, negotiated per device: AV1 is offered in SDP only when the device reports HW AV1, otherwise H.264 only.
- **Encoders.** PJSIP encodes with hardware acceleration: VideoToolbox on iOS (`PJMEDIA_HAS_VID_TOOLBOX_CODEC`) and MediaCodec on Android (`PJMEDIA_HAS_ANDROID_MEDIACODEC`). Both are enabled in the branch CI builds of the pjproject libraries.
- **Simulcast.** Simulcast goes through mediasoup (§8). Each subscriber gets the layer it can handle (bandwidth/CPU/screen).
- **QuickHD-style start.** For the first ~3–5 s of a call, the encoder starts at the high layer at an elevated bitrate (keyframe-forward) for instant sharpness, then hands off to normal rate adaptation.
- **Tuning.** Encoder parameters (bitrates per layer, keyframe interval, QuickHD duration/boost) are starting values and **will be iterated from production data**.

## 11. Must-pass call matrix (Donny t4460u) — nothing ships until every row passes

Pass = callee rings, answers, and the receiver gets decoded media for >=30 s: audio RMS > 0.05 / video frames >= 15 fps with non-black content, srtpErr = 0, teardown clean. Then a redial within 30 s passes again.

| # | Caller → Callee | Media | Direction checked | Automated check |
|---|---|---|---|---|
| 1 | iPhone → iPhone | audio | iPhone→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 2 | iPhone → iPhone | audio | iPhone→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 3 | iPhone → iPhone | video | iPhone→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 4 | iPhone → iPhone | video | iPhone→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 5 | iPhone → Android | audio | iPhone→Android | XCUITest on device farm/sim + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 6 | iPhone → Android | audio | Android→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 7 | iPhone → Android | video | iPhone→Android | XCUITest on device farm/sim + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 8 | iPhone → Android | video | Android→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 9 | iPhone → Browser | audio | iPhone→Browser | XCUITest on device farm/sim + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 10 | iPhone → Browser | audio | Browser→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 11 | iPhone → Browser | video | iPhone→Browser | XCUITest on device farm/sim + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 12 | iPhone → Browser | video | Browser→iPhone | XCUITest on device farm/sim + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 13 | Android → iPhone | audio | Android→iPhone | instrumented test (emulator) + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 14 | Android → iPhone | audio | iPhone→Android | instrumented test (emulator) + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 15 | Android → iPhone | video | Android→iPhone | instrumented test (emulator) + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 16 | Android → iPhone | video | iPhone→Android | instrumented test (emulator) + pjsua stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 17 | Android → Android | audio | Android→Android | instrumented test (emulator) + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 18 | Android → Android | audio | Android→Android | instrumented test (emulator) + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 19 | Android → Android | video | Android→Android | instrumented test (emulator) + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 20 | Android → Android | video | Android→Android | instrumented test (emulator) + pjsua stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 21 | Android → Browser | audio | Android→Browser | instrumented test (emulator) + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 22 | Android → Browser | audio | Browser→Android | instrumented test (emulator) + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 23 | Android → Browser | video | Android→Browser | instrumented test (emulator) + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 24 | Android → Browser | video | Browser→Android | instrumented test (emulator) + pjsua stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 25 | Browser → iPhone | audio | Browser→iPhone | Playwright (fake mic/cam) + WASM stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 26 | Browser → iPhone | audio | iPhone→Browser | Playwright (fake mic/cam) + WASM stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 27 | Browser → iPhone | video | Browser→iPhone | Playwright (fake mic/cam) + WASM stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 28 | Browser → iPhone | video | iPhone→Browser | Playwright (fake mic/cam) + WASM stats ⇄ XCUITest on device farm/sim + pjsua stats; tone/test-pattern injected, received signal analysed |
| 29 | Browser → Android | audio | Browser→Android | Playwright (fake mic/cam) + WASM stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 30 | Browser → Android | audio | Android→Browser | Playwright (fake mic/cam) + WASM stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 31 | Browser → Android | video | Browser→Android | Playwright (fake mic/cam) + WASM stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 32 | Browser → Android | video | Android→Browser | Playwright (fake mic/cam) + WASM stats ⇄ instrumented test (emulator) + pjsua stats; tone/test-pattern injected, received signal analysed |
| 33 | Browser → Browser | audio | Browser→Browser | Playwright (fake mic/cam) + WASM stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 34 | Browser → Browser | audio | Browser→Browser | Playwright (fake mic/cam) + WASM stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 35 | Browser → Browser | video | Browser→Browser | Playwright (fake mic/cam) + WASM stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |
| 36 | Browser → Browser | video | Browser→Browser | Playwright (fake mic/cam) + WASM stats ⇄ Playwright (fake mic/cam) + WASM stats; tone/test-pattern injected, received signal analysed |

CI stage 1: Linux pjsua⇄pjsua (exists, green) + pjsua⇄WASM-in-headless-Chrome. Stage 2: simulator/emulator pairs through mediasoup on a test droplet (not prod). Stage 3: real devices (Keiko Android → Donny iPhone, locked phone, redial ×5) — manual sign-off rows.
