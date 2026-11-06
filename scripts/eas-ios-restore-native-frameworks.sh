#!/usr/bin/env bash
# EAS packs the project with .gitignore, so modules/.../WebRTC.xcframework (gitignored)
# is omitted or left as an empty stub in the eas-build-local temp copy. CocoaPods then
# fails: "plist file at .../WebRTC.xcframework/Info.plist doesn't exist".
# This hook runs as eas-build-post-install (after npm ci, before pod install) and
# re-fetches WebRTC into the *current* build tree. pjproject is not gitignored; CI
# must place it on disk before `eas build --local` so the pack includes it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Only needed for iOS native builds (skip Android EAS / local JS).
if [[ "${EAS_BUILD_PLATFORM:-ios}" != "ios" ]]; then
  echo "eas-ios-restore-native-frameworks: skip (platform=${EAS_BUILD_PLATFORM:-unset})"
  exit 0
fi

export OL_WEBRTC_IOS_CACHE="${OL_WEBRTC_IOS_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/webrtc-bsd-m152-ios}"

IOS_MOD="$ROOT/modules/openlounge-call-engine/ios"
test -d "$IOS_MOD" || { echo "FAIL: missing $IOS_MOD" >&2; exit 1; }

# Drop empty/partial stub left by gitignore filtering so File.exist? is honest until fetch.
if [[ -d "$IOS_MOD/WebRTC.xcframework" && ! -f "$IOS_MOD/WebRTC.xcframework/Info.plist" ]]; then
  echo "Removing incomplete WebRTC.xcframework stub"
  rm -rf "$IOS_MOD/WebRTC.xcframework"
fi

bash "$ROOT/scripts/ios-fetch-webrtc.sh"
test -f "$IOS_MOD/WebRTC.xcframework/Info.plist"
test -d "$IOS_MOD/WebRTC.xcframework/ios-arm64"

if [[ ! -f "$IOS_MOD/pjproject.xcframework/Info.plist" ]]; then
  echo "FAIL: pjproject.xcframework missing in EAS build tree." >&2
  echo "CI must download/build pjproject into modules/openlounge-call-engine/ios/ before eas --local." >&2
  exit 1
fi

ruby -e '
  dir = ARGV[0]
  abort("WebRTC.xcframework missing") unless File.exist?(File.join(dir, "WebRTC.xcframework"))
  abort("pjproject.xcframework missing") unless File.exist?(File.join(dir, "pjproject.xcframework"))
  vf = ["pjproject.xcframework"] + (File.exist?(File.join(dir, "WebRTC.xcframework")) ? ["WebRTC.xcframework"] : [])
  abort("podspec would omit WebRTC") unless vf.include?("WebRTC.xcframework")
  puts "eas-ios-restore-native-frameworks OK — vendored: #{vf.join(" + ")}"
' "$IOS_MOD"
