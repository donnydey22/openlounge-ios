#!/usr/bin/env bash
# Fails if any tracked file references a calling stack this project does not have.
# Open Lounge calling on iOS has exactly one path, the same as the Android olcall build:
#   call control  the openlounge.app page in the app's WKWebView: call:start / call:accept / call:get
#                 on its own signed-in realtime socket (Railway). The app never opens that socket.
#   media / ICE   OLTgcallsEngine -> wss://turn.openlounge.app/v1/call (Pion); direct pairs first, TURN relay when direct fails.
set -euo pipefail
cd "$(dirname "$0")/.."
self="ci/clean-slate.sh"
files=$(git ls-files | grep -v -x "$self" || true)
[ -n "$files" ] || { echo "clean-slate: no tracked files" >&2; exit 2; }

ci_patterns='\bp2p\b|livekit|ringrtc|pjsip|pjnath|mediasoup|streamwebrtc|stream-webrtc|\bsfu\b|react-native|\bexpo\b|cocoapods|podspec|legacy|fallback|migration|\bshim\b|deprecated|\bretired\b|\bold (socket|engine|path|webrtc|app|audio|ui|call)|openlounge\.app/ws|"/ws"|rtc:iceconfig|call:p2p|olnativecallhost|olcallmanager|olaudiosessionowner|olcallaudiohost|callsignalclient|olcalldisklog|openloungecallengine|openloungecalls\b|openloungeolcall|olcallsession|olsignalingrelay|oltgcallscall\b|olcallroute|oltgcallsversion|olrtccall|olrtcvideo|olcallaudioengine|rtcpeerconnection|rtcaudiosession|nativecallmedia|olnativeaudio|ollanebridge|oltelecomcore'
cs_patterns='WebRTC\.xcframework|WebRTC\.framework|import WebRTC\b'

hits=0
out=$(echo "$files" | xargs grep -n -I -i -E "$ci_patterns" -- 2>/dev/null || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi
out=$(echo "$files" | xargs grep -n -I -E "$cs_patterns" -- 2>/dev/null || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi
# The engine's ICE switch is the one allowed mention of the word: true, as on the working Android path (direct first, TURN relay when direct fails).
out=$(echo "$files" | xargs grep -n -I -E 'allowP2P' -- 2>/dev/null | grep -v -E 'allowP2P: true,' || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi

# The call log states the engine's ICE policy: with the ICE switch above on, the log must not default to relayOnly (b132 logged
# relayOnly: true on calls Pion connected directly).
if ! grep -q -E '^    public var relayOnly = false$' OLCall/Sources/OLCallCore/OLCallLog.swift; then
  echo "OLCall/Sources/OLCallCore/OLCallLog.swift: relayOnly default must be false while the engine ICE switch is on (direct first)"; hits=$((hits + 1))
fi

# Call control belongs to the page: no app or package source names the realtime socket's call
# events, and the engine is the only code that opens a WebSocket (to /v1/call).
src=$(echo "$files" | grep -E '\.(swift|m|mm|h|c|cpp|plist|yml)$' || true)
out=$(echo "$src" | xargs grep -n -I -E 'call:(start|accept|get)\b' -- 2>/dev/null || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi
out=$(echo "$src" | xargs grep -n -I -E 'webSocketTask|URLSessionWebSocketTask|SRWebSocket|Starscream|NWProtocolWebSocket' -- 2>/dev/null \
  | grep -v -E '^OLCall/Sources/OLCall/OLTgcallsEngine\.swift:' || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi
# The page's capability name "rtcP2P" (= "this app owns call media") appears only in the capability list.
out=$(echo "$files" | xargs grep -n -I 'rtcP2P' -- 2>/dev/null | grep -v -E '^OLCall/Sources/OLShellCore/OLBridgeScript\.swift:|^OLCall/Tests/OLShellCoreTests/|^(README|CHECKLIST)\.md:' || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi

echo "clean-slate: files=$(echo "$files" | wc -l | tr -d ' ') hits=$hits"
[ "$hits" -eq 0 ] || { echo "FAIL: references to calling stacks this project does not have" >&2; exit 1; }
echo "PASS: clean slate (0 hits)"
