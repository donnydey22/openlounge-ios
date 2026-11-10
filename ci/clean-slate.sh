#!/usr/bin/env bash
# Fails if any tracked file references a calling stack this project does not have.
# Open Lounge calling on iOS has exactly one path: OLTgcallsEngine -> wss /v1/call (Pion) over TURN.
set -euo pipefail
cd "$(dirname "$0")/.."
self="ci/clean-slate.sh"
files=$(git ls-files | grep -v -x "$self" || true)
[ -n "$files" ] || { echo "clean-slate: no tracked files" >&2; exit 2; }

ci_patterns='\bp2p\b|livekit|ringrtc|pjsip|pjnath|mediasoup|streamwebrtc|stream-webrtc|\bsfu\b|webview|react-native|\bexpo\b|cocoapods|podspec|legacy|fallback|migration|\bshim\b|deprecated|\bretired\b|\bold (socket|engine|path|webrtc|app|audio|ui|call)|openlounge\.app/ws|"/ws"|rtc:iceconfig|call:p2p|olnativecallhost|olcallmanager|olaudiosessionowner|olcallaudiohost|callsignalclient|olcalldisklog|openloungecallengine|openloungecalls\b|openloungeolcall|olcallsession|olsignalingrelay|oltgcallscall\b|olcallroute|oltgcallsversion|olrtccall|olrtcvideo|olcallaudioengine|rtcpeerconnection|rtcaudiosession|nativecallmedia|olnativeaudio|ollanebridge|oltelecomcore'
cs_patterns='WebRTC\.xcframework|WebRTC\.framework|import WebRTC\b'

hits=0
out=$(echo "$files" | xargs grep -n -I -i -E "$ci_patterns" -- 2>/dev/null || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi
out=$(echo "$files" | xargs grep -n -I -E "$cs_patterns" -- 2>/dev/null || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi
# The engine's relay-only switch is the one allowed mention of the word, and it must say false.
out=$(echo "$files" | xargs grep -n -I -E 'allowP2P' -- 2>/dev/null | grep -v -E 'allowP2P: false,' || true)
if [ -n "$out" ]; then echo "$out"; hits=$((hits + $(echo "$out" | wc -l))); fi

echo "clean-slate: files=$(echo "$files" | wc -l | tr -d ' ') hits=$hits"
[ "$hits" -eq 0 ] || { echo "FAIL: references to calling stacks this project does not have" >&2; exit 1; }
echo "PASS: clean slate (0 hits)"
