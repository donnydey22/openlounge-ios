#!/usr/bin/env bash
# Build + test the OLTgcalls Swift package for iOS (device arm64 + simulator arm64).
# macOS + Xcode ONLY. Fails loudly anywhere else.
#
#   ios/OLTgcallsSwift/build.sh <TgVoipWebrtc.xcframework | Telegram-iOS tree>
#
# Steps:
#   1. sync  audio/core -> Sources/OLAudioCore (single source of truth stays audio/core)
#   2. xcframework -> Frameworks/TgVoipWebrtc.xcframework. Given a Telegram-iOS tree,
#      it first installs ios/OLTgVoipXCFramework there and builds
#      //OLTgVoipXCFramework:TgVoipWebrtc with the tree's own Make.py.
#      Adds Modules/module.modulemap to any slice that lacks one.
#   3. xcodebuild build  -destination generic/platform=iOS            (device arm64)
#   4. xcodebuild build  -destination generic/platform=iOS Simulator  (simulator arm64)
#   5. xcodebuild test   on a booted iPhone simulator (OLTgcallsTests: version pick +
#      golden frames shared with olcall/integration Go tests)
# Output: build/OLTgcalls-<UTC>.log + build/RESULT.json. Exit 0 iff all steps pass.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "BLOCKED: OLTgcalls builds only on macOS with Xcode (this host: $(uname -s)). Nothing was built." >&2
  exit 2
fi
command -v xcodebuild >/dev/null || { echo "BLOCKED: xcodebuild not found (install Xcode; the pin wants $(sed -n 's/.*"xcode": *"\([^"]*\)".*/\1/p' "$(dirname "$0")/../../ci/telegram-ios-versions.pin"))" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
src="${1:?usage: build.sh <TgVoipWebrtc.xcframework | Telegram-iOS tree>}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$here/build"
log="$here/build/OLTgcalls-$stamp.log"
exec > >(tee "$log") 2>&1
xcodebuild -version

echo "== 1. sync audio/core -> Sources/OLAudioCore"
rm -rf "$here/Sources/OLAudioCore"
mkdir -p "$here/Sources/OLAudioCore/include"
cp "$root/audio/core/ol_audio.h" "$here/Sources/OLAudioCore/include/"
cp "$root/audio/core/ol_session_policy.c" "$here/Sources/OLAudioCore/"

echo "== 2. TgVoipWebrtc.xcframework"
xcf=""
if [ -d "$src" ] && [ "${src%.xcframework}" != "$src" ]; then
  xcf="$src"
elif [ -d "$src/submodules/TgVoipWebrtc" ]; then
  bash "$root/ios/install-into-telegram-ios.sh" "$src" org.openlounge.oltgpeertest
  (cd "$src" && python3 build-system/Make/Make.py --overrideXcodeVersion build \
      --configurationPath=build-system/template_minimal_development_configuration.json \
      --codesigningInformationPath=build-system/fake-codesigning --disableProvisioningProfiles \
      --configuration=release_arm64 --buildNumber=1 --target=//OLTgVoipXCFramework:TgVoipWebrtc)
  xcf="$src/bazel-bin/OLTgVoipXCFramework/TgVoipWebrtc.xcframework"
fi
[ -n "$xcf" ] && [ -f "$xcf/Info.plist" ] || { echo "FAIL: no TgVoipWebrtc.xcframework from $src" >&2; exit 1; }
rm -rf "$here/Frameworks"; mkdir -p "$here/Frameworks"
cp -R "$xcf" "$here/Frameworks/TgVoipWebrtc.xcframework"
for slice in "$here"/Frameworks/TgVoipWebrtc.xcframework/*/; do
  [ -d "$slice" ] || continue
  if [ -d "$slice/TgVoipWebrtc.framework" ]; then
    fw="$slice/TgVoipWebrtc.framework"
    if [ ! -f "$fw/Modules/module.modulemap" ]; then
      mkdir -p "$fw/Modules"
      printf 'framework module TgVoipWebrtc {\n  header "OngoingCallThreadLocalContext.h"\n  export *\n}\n' > "$fw/Modules/module.modulemap"
      echo "added modulemap: $fw"
    fi
  elif [ -d "$slice/Headers" ] && [ ! -f "$slice/Headers/module.modulemap" ]; then
    hdr="$(cd "$slice/Headers" && find . -name OngoingCallThreadLocalContext.h | head -n1)"
    [ -n "$hdr" ] || { echo "FAIL: slice $slice has no OngoingCallThreadLocalContext.h" >&2; exit 1; }
    printf 'module TgVoipWebrtc {\n  header "%s"\n  export *\n}\n' "${hdr#./}" > "$slice/Headers/module.modulemap"
    echo "added modulemap: $slice/Headers"
  fi
done
grep -q "ios-arm64-simulator\|ios-arm64_x86_64-simulator" "$here/Frameworks/TgVoipWebrtc.xcframework/Info.plist" \
  || { echo "FAIL: xcframework has no simulator slice" >&2; exit 1; }

cd "$here"
results=()
run() { local name="$1"; shift; echo "== $name"; if "$@"; then results+=("\"$name\":true"); else results+=("\"$name\":false"); fi; }
dd="$here/build/dd"
run build_device xcodebuild -scheme OLTgcalls -destination 'generic/platform=iOS' -derivedDataPath "$dd" \
  -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=NO BUILD_LIBRARY_FOR_DISTRIBUTION=NO build
run build_simulator xcodebuild -scheme OLTgcalls -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" \
  -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
sim="$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone [^()]*\) (\([0-9A-F-]*\)).*/\2/p' | head -n1)"
if [ -n "$sim" ]; then
  run test_simulator xcodebuild -scheme OLTgcalls-Package -destination "id=$sim" -derivedDataPath "$dd" test
else
  echo "no available iPhone simulator"; results+=("\"test_simulator\":false")
fi

printf '{"utc":"%s","xcode":"%s",%s}\n' "$stamp" "$(xcodebuild -version | head -n1)" "$(IFS=,; echo "${results[*]}")" > "$here/build/RESULT.json"
cat "$here/build/RESULT.json"
case "${results[*]}" in *false*) echo "FAIL (see $log)"; exit 1;; esac
echo "PASS: OLTgcalls built for iOS device + simulator and tests passed (no device call made)"
