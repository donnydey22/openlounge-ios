#!/usr/bin/env bash
# RingRTC session-model hard cut: PJSIP / mediasoup SFU legs must never return to the iOS calling engine.
set -euo pipefail
cd "$(dirname "$0")/.."
hits=$(grep -rnE 'pjsua|pjmedia|pjlib|pj_[a-z]|ol_sfu|ol_p2p|NativeCallMedia|PJSIPEngine|OLPjsip|pjproject\.xcframework' \
  modules/openlounge-call-engine/ios modules/openlounge-calls/ios --include='*.swift' --include='*.c' --include='*.h' --include='*.m' --include='*.podspec' \
  --exclude-dir=WebRTC.xcframework || true)
if [ -n "$hits" ]; then echo "FAIL: PJSIP/SFU calling code reintroduced:"; echo "$hits"; exit 1; fi
echo "OK: no PJSIP in iOS calling engine"
