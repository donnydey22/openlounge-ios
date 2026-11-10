#!/usr/bin/env bash
# Mac CI for the Open Lounge iOS app (macOS + Xcode only).
#   ci/build.sh <TgVoipWebrtc.xcframework.zip>
# 1. clean-slate check     ci/clean-slate.sh
# 2. engine xcframework     -> OLCall/Frameworks/TgVoipWebrtc.xcframework
# 3. OLCall package tests   (OLCallCoreTests + OLCallTests) on an iPhone simulator
# 4. app build              simulator arm64 (Debug) + device arm64 (Release), unsigned
# 5. duplicate classes      ci/dup-classes.sh on both app builds
# Writes build/RESULT.json; exit 0 only if every step passed.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "BLOCKED: macOS + Xcode only" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
zip="${1:?usage: ci/build.sh <TgVoipWebrtc.xcframework.zip>}"
cd "$root"
mkdir -p build
log="build/ci-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee "$log") 2>&1
xcodebuild -version

results=()
run() { local name="$1"; shift; echo "== $name"; if "$@"; then results+=("\"$name\":true"); else results+=("\"$name\":false"); fi; }

run clean_slate bash ci/clean-slate.sh

echo "== xcframework"
rm -rf build/xcf build/xcf-lib OLCall/Frameworks
mkdir -p build/xcf build/xcf-lib OLCall/Frameworks
ditto -x -k "$zip" build/xcf
xcf="$(find build/xcf -maxdepth 2 -type d -name 'TgVoipWebrtc.xcframework' | head -n1)"
[ -n "$xcf" ] && [ -f "$xcf/Info.plist" ] || { echo "FAIL: no TgVoipWebrtc.xcframework in $zip" >&2; exit 1; }
# The engine is a static library. Repackage every slice as a library xcframework (static archive +
# headers + module map) so Xcode links it into the app binary and embeds nothing.
args=()
for slice in "$xcf"/*/; do
  [ -d "$slice" ] || continue
  name="$(basename "$slice")"
  if [ -d "$slice/TgVoipWebrtc.framework" ]; then
    fw="$slice/TgVoipWebrtc.framework"; bin="$fw/TgVoipWebrtc"; hdrs="$fw/Headers"
  else
    bin="$(find "$slice" -maxdepth 1 -name '*.a' | head -n1)"; hdrs="$slice/Headers"
  fi
  [ -f "$bin" ] && [ -d "$hdrs" ] || { echo "FAIL: slice $name has no binary/headers" >&2; exit 1; }
  file "$bin"
  out="build/xcf-lib/$name"; mkdir -p "$out/Headers"
  cp "$bin" "$out/libTgVoipWebrtc.a"
  cp -R "$hdrs/." "$out/Headers/"
  rm -f "$out/Headers/module.modulemap"
  top="$(cd "$out/Headers" && find . -name OngoingCallThreadLocalContext.h | head -n1)"
  [ -n "$top" ] || { echo "FAIL: slice $name has no OngoingCallThreadLocalContext.h" >&2; exit 1; }
  printf 'module TgVoipWebrtc {\n  header "%s"\n  export *\n}\n' "${top#./}" > "$out/Headers/module.modulemap"
  args+=(-library "$out/libTgVoipWebrtc.a" -headers "$out/Headers")
done
xcodebuild -create-xcframework "${args[@]}" -output OLCall/Frameworks/TgVoipWebrtc.xcframework
ls OLCall/Frameworks/TgVoipWebrtc.xcframework

sim="$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone [^()]*\) (\([0-9A-F-]*\)).*/\2/p' | head -n1)"
[ -n "$sim" ] || { echo "FAIL: no iPhone simulator" >&2; exit 1; }
echo "simulator: $sim"

pkg_tests() {
  (cd OLCall && xcodebuild -scheme OLCall-Package -destination "id=$sim" -derivedDataPath "$root/build/dd-pkg" \
     -resultBundlePath "$root/build/OLCall-tests.xcresult" test)
}
run package_tests pkg_tests

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --spec project.yml

app_sim() {
  xcodebuild -project OpenLounge.xcodeproj -scheme OpenLounge -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd-app \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
}
app_device() {
  xcodebuild -project OpenLounge.xcodeproj -scheme OpenLounge -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/dd-app \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
}
run app_build_simulator app_sim
run app_build_device app_device

dups() {
  local ok=0
  for a in build/dd-app/Build/Products/Debug-iphonesimulator/OpenLounge.app build/dd-app/Build/Products/Release-iphoneos/OpenLounge.app; do
    bash ci/dup-classes.sh "$a" || ok=1
  done
  return $ok
}
run duplicate_classes dups

tests="$(awk "/^Test Suite '.*\\.xctest' (passed|failed)/{getline; print}" "$log" | sed -n 's/.*Executed \([0-9]*\) tests\{0,1\}, with \([0-9]*\) failures.*/\1 \2/p' | awk '{e+=$1; f+=$2} END {print e" "f}')"
echo "tests (executed failures): ${tests:-unknown}"
printf '{"xcode":"%s","tests":"%s",%s}\n' "$(xcodebuild -version | head -n1)" "${tests:-unknown}" "$(IFS=,; echo "${results[*]}")" > build/RESULT.json
cat build/RESULT.json
case "${results[*]}" in *false*) echo "FAIL (see $log)"; exit 1;; esac
echo "PASS: clean slate, OLCall tests green, app built for simulator + device, 0 duplicate classes"
