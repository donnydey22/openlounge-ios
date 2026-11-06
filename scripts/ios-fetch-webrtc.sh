#!/usr/bin/env bash
# Fetch interim BSD Google WebRTC.xcframework (M152 / branch-heads/7977) for OpenLoungeCallEngine.
# Same Chromium milestone as Android /workspace/webrtc-bsd/m152 (crow-misia 152.7977.0.0).
# Source: stasel/WebRTC release 152.0.0 — unmodified official WebRTC, BSD-3. NOT RingRTC/AGPL.
# Signal fork 8037b remains the eventual target; see /workspace/builds/signal-webrtc/build-signal-webrtc-ios.sh (Mac).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/modules/openlounge-call-engine/ios/WebRTC.xcframework"
CACHE="${OL_WEBRTC_IOS_CACHE:-/workspace/webrtc-bsd/m152-ios}"
URL="${OL_WEBRTC_IOS_URL:-https://github.com/stasel/WebRTC/releases/download/152.0.0/WebRTC-M152.xcframework.zip}"
EXPECT_SHA="${OL_WEBRTC_IOS_SHA256:-115cb9944248a3302c0c8af17462e2576a28ccc7adef9f6a1fe66ee75d9e1cc8}"
VERSION_LABEL="${OL_WEBRTC_IOS_VERSION:-stasel/WebRTC 152.0.0 (M152 / branch-heads/7977 / commit 6f37672d358475cd17544121a12494da454d85fb)}"

mkdir -p "$CACHE"
ZIP="$CACHE/WebRTC-M152.xcframework.zip"
if [[ ! -f "$ZIP" ]]; then
  echo "Downloading $URL → $ZIP"
  curl -L --fail --retry 3 --retry-delay 2 -o "$ZIP.partial" "$URL"
  mv "$ZIP.partial" "$ZIP"
fi
ACTUAL="$(sha256sum "$ZIP" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECT_SHA" ]]; then
  echo "SHA256 mismatch for $ZIP" >&2
  echo "  expected: $EXPECT_SHA" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
rm -rf "$CACHE/unpack" "$DEST"
mkdir -p "$CACHE/unpack"
unzip -q "$ZIP" -d "$CACHE/unpack"
XCF="$(find "$CACHE/unpack" -maxdepth 3 -type d -name 'WebRTC.xcframework' | head -1)"
[[ -n "$XCF" ]] || { echo "WebRTC.xcframework not found inside zip" >&2; exit 1; }
cp -a "$XCF" "$DEST"
cp -a "$XCF" "$CACHE/WebRTC.xcframework"
{
  echo "source=$VERSION_LABEL"
  echo "url=$URL"
  echo "zip_sha256=$EXPECT_SHA"
  echo "placed=$DEST"
  du -sh "$DEST" | awk '{print "size="$1}'
} | tee "$CACHE/SOURCE.txt" "$DEST/../WebRTC.xcframework.SOURCE.txt"
echo "OK: $DEST"
