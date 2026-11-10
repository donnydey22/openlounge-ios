#!/usr/bin/env bash
# Install OLTgPeerTest (iOS<->Pion proof app) and OLTgVoipXCFramework (the
# engine xcframework for the OL app) into a Telegram-iOS checkout
# (pinned 24638bc; macOS + Xcode per versions.json).
#
#   ios/install-into-telegram-ios.sh /path/to/Telegram-iOS com.yourteam.oltgpeertest [OLTgPeerTest.mobileprovision]
#
# Without a profile: builds for the simulator only (CI compile proof).
# With a profile (development profile for the bundle id, YOUR Apple team): the
# profile is copied to build-input/configuration-repository/provisioning/ and
# exported, so the device build can sign. The profile is never printed or
# committed by this script.
#
# Build commands (run from the Telegram-iOS root):
#   simulator:
#     python3 build-system/Make/Make.py --overrideXcodeVersion build \
#       --configurationPath=build-system/template_minimal_development_configuration.json \
#       --codesigningInformationPath=build-system/fake-codesigning \
#       --disableProvisioningProfiles --configuration=debug_sim_arm64 --buildNumber=1 \
#       --target=//OLTgPeerTest:OLTgPeerTest
#   device:
#     python3 build-system/Make/Make.py --overrideXcodeVersion build \
#       --configurationPath=<your configuration json> \
#       --codesigningInformationPath=<your codesigning dir> \
#       --configuration=debug_arm64 --buildNumber=1 --target=//OLTgPeerTest:OLTgPeerTest
#   then install bazel-bin/OLTgPeerTest/OLTgPeerTest.ipa with Xcode (Devices window) or
#   `xcrun devicectl device install app --device <UDID> bazel-bin/OLTgPeerTest/OLTgPeerTest.ipa`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tree="${1:?usage: install-into-telegram-ios.sh /path/to/Telegram-iOS bundle.id [profile]}"
bundle="${2:?bundle id required}"
profile="${3:-}"
test -d "$tree/submodules/TgVoipWebrtc" || { echo "not a Telegram-iOS tree: $tree"; exit 1; }
case "$bundle" in *[!A-Za-z0-9.-]*) echo "bad bundle id: $bundle"; exit 1;; esac

dst="$tree/OLTgPeerTest"
mkdir -p "$dst"
rm -rf "$dst/Sources"
cp -R "$here/OLTgPeerTest/Sources" "$dst/"
cp "$here/OLTgPeerTest/Info.plist" "$dst/"
sed "s/{BUNDLE_ID}/$bundle/" "$here/OLTgPeerTest/BUILD.bazel" > "$dst/BUILD"
echo "installed $dst (bundle $bundle)"

# Static xcframework of TgVoipWebrtc for the OL app (Expo pod). Its public_hdrs
# reference the PublicHeaders of //submodules/TgVoipWebrtc, which that package
# does not export at the pin: append an exports_files (idempotent, additive).
xdst="$tree/OLTgVoipXCFramework"
mkdir -p "$xdst"
cp "$here/OLTgVoipXCFramework/BUILD.bazel" "$xdst/BUILD"
tgbuild="$tree/submodules/TgVoipWebrtc/BUILD"
if ! grep -q 'olcall: export public headers' "$tgbuild"; then
  printf '\n# olcall: export public headers for //OLTgVoipXCFramework (added by ol install-into-telegram-ios.sh)\nexports_files(glob(["PublicHeaders/**/*.h"]))\n' >> "$tgbuild"
fi
echo "installed $xdst (+ exports_files in submodules/TgVoipWebrtc/BUILD)"

if [ -n "$profile" ]; then
  prov="$tree/build-input/configuration-repository/provisioning"
  test -d "$prov" || { echo "no $prov: run Make.py once with your --configurationPath first"; exit 1; }
  cp "$profile" "$prov/OLTgPeerTest.mobileprovision"
  if ! grep -q '"OLTgPeerTest.mobileprovision"' "$prov/BUILD"; then
    # append to exports_files([...]) without touching other entries
    tmp="$(mktemp)"
    awk '{print} /exports_files\(\[/ && !done {print "\t\"OLTgPeerTest.mobileprovision\","; done=1}' "$prov/BUILD" > "$tmp"
    mv "$tmp" "$prov/BUILD"
  fi
  echo "profile installed as @build_configuration//provisioning:OLTgPeerTest.mobileprovision"
fi

# Sanity: the pinned values baked into BUILD must still match this tree.
grep -q 'minimum_os_version = "15.0"' "$tree/Telegram/BUILD" || echo "WARNING: Telegram/BUILD minimum_os_version is no longer 15.0; update MINIMUM_OS in $dst/BUILD"
grep -q -- '-DTGVOIP_NAMESPACE=tgvoip_webrtc' "$tree/submodules/TgVoipWebrtc/BUILD" || echo "WARNING: TgVoipWebrtc copts changed; re-sync TGVOIP_COPTS in $dst/BUILD"
grep -q 'AudioDeviceModuleIOS(bool bypass_voice_processing, bool disable_recording, bool enableSystemMute, int numChannels)' \
  "$tree/submodules/TgVoipWebrtc/tgcalls/tgcalls/platform/darwin/iOS/tgcalls_audio_device_module_ios.h" \
  || echo "WARNING: AudioDeviceModuleIOS constructor changed; update OLTgPeer.mm"
