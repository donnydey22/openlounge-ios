#!/usr/bin/env bash
# Restore WebRTC into the EAS build tree before pod install.
# Why: repo .gitignore omits WebRTC.xcframework; without .easignore un-ignore (or this
# hook), EAS packs an empty stub and CocoaPods fails on missing Info.plist.
# Prefer: .easignore includes the framework after CI fetch. This script is belt-and-suspenders.
set -euo pipefail
echo "=== eas-ios-restore-native-frameworks: START cwd=$(pwd) EAS_BUILD_PLATFORM=${EAS_BUILD_PLATFORM:-unset} ==="
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "=== eas-ios-restore-native-frameworks: ROOT=$ROOT ==="

if [[ "${EAS_BUILD_PLATFORM:-ios}" != "ios" ]]; then
  echo "=== eas-ios-restore-native-frameworks: skip (platform=${EAS_BUILD_PLATFORM:-unset}) ==="
  exit 0
fi

export OL_WEBRTC_IOS_CACHE="${OL_WEBRTC_IOS_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/webrtc-bsd-m152-ios}"
IOS_MOD="$ROOT/modules/openlounge-call-engine/ios"
test -d "$IOS_MOD" || { echo "FAIL: missing $IOS_MOD" >&2; exit 1; }

if [[ -d "$IOS_MOD/WebRTC.xcframework" && ! -f "$IOS_MOD/WebRTC.xcframework/Info.plist" ]]; then
  echo "=== Removing incomplete WebRTC.xcframework stub ==="
  rm -rf "$IOS_MOD/WebRTC.xcframework"
fi

if [[ -f "$IOS_MOD/WebRTC.xcframework/Info.plist" && -d "$IOS_MOD/WebRTC.xcframework/ios-arm64" ]]; then
  echo "=== WebRTC.xcframework already present (likely via .easignore pack) — refresh optional ==="
  # Still re-fetch if incomplete slices; otherwise keep packed copy to save time.
  du -sh "$IOS_MOD/WebRTC.xcframework" || true
else
  echo "=== Fetching WebRTC.xcframework into EAS build tree ==="
  bash "$ROOT/scripts/ios-fetch-webrtc.sh"
fi

test -f "$IOS_MOD/WebRTC.xcframework/Info.plist"
test -d "$IOS_MOD/WebRTC.xcframework/ios-arm64"


ruby -e '
  dir = ARGV[0]
  abort("WebRTC.xcframework missing") unless File.exist?(File.join(dir, "WebRTC.xcframework"))
  vf = File.exist?(File.join(dir, "WebRTC.xcframework")) ? ["WebRTC.xcframework"] : []
  abort("podspec would omit WebRTC") unless vf.include?("WebRTC.xcframework")
  puts "=== eas-ios-restore-native-frameworks OK — vendored: #{vf.join(" + ")} ==="
' "$IOS_MOD"
echo "=== eas-ios-restore-native-frameworks: DONE ==="
