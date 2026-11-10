#!/usr/bin/env bash
# Installs the xcframework target into a Telegram-iOS checkout at the pinned commit and builds it.
#   ci/xcframework/install.sh <Telegram-iOS tree> <output dir>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tree="${1:?Telegram-iOS tree}"; out="${2:?output dir}"
test -d "$tree/submodules/TgVoipWebrtc" || { echo "not a Telegram-iOS tree: $tree" >&2; exit 1; }
mkdir -p "$tree/OLTgVoipXCFramework" "$out"
cp "$here/BUILD.bazel" "$tree/OLTgVoipXCFramework/BUILD"
tgbuild="$tree/submodules/TgVoipWebrtc/BUILD"
grep -q 'olcall: export public headers' "$tgbuild" || \
  printf '\n# olcall: export public headers for //OLTgVoipXCFramework\nexports_files(glob(["PublicHeaders/**/*.h"]))\n' >> "$tgbuild"
# Portrait capture (t5457): tgcalls' VideoCameraCapturer already has a rotation lock (_rotationLock, read in
# captureOutput) that nothing sets. Set it at init so the frame rotation stays at the init value; the app is
# portrait-only (Info.plist), so that is RTCVideoRotation_90 (portrait) whatever the phone's tilt.
cap="$tree/submodules/TgVoipWebrtc/tgcalls/tgcalls/platform/darwin/VideoCameraCapturer.mm"
python3 - "$cap" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
mark = "_rotationLock = true; // olcall: portrait capture"
anchor = "_rotationUpdated = [rotationUpdated copy];"
if mark not in s:
    if s.count(anchor) != 1 or "if (!_rotationLock) {" not in s:
        sys.exit("FAIL: VideoCameraCapturer.mm rotation-lock anchor not found")
    s = s.replace(anchor, anchor + "\n        " + mark)
    open(p, "w").write(s)
print("portrait capture lock: applied")
PY
(cd "$tree" && python3 build-system/Make/Make.py --overrideXcodeVersion build \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning \
    --configuration=release_arm64 --buildNumber=1 --target=//OLTgVoipXCFramework:TgVoipWebrtc)
z="$tree/bazel-bin/OLTgVoipXCFramework/TgVoipWebrtc.xcframework.zip"
[ -f "$z" ] || { echo "FAIL: $z not produced" >&2; exit 1; }
cp "$z" "$out/TgVoipWebrtc.xcframework.zip"
echo "xcframework: $(du -h "$out/TgVoipWebrtc.xcframework.zip")"
