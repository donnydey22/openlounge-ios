#!/usr/bin/env bash
# Add the OpenLoungeOlcall Expo module to the OL iOS app (Expo / React Native,
# pj-openlounge-ios; UI baseline iOS native 7aaac81 per the UI-restoration
# BASELINE). Run on a clone/branch, never on the original checkout:
#
#   ios/install-into-ol-app.sh <ol-ios-app-clone> <TgVoipWebrtc.xcframework>
#
# Adds ONLY: <app>/modules/openlounge-olcall/** (Expo autolinks local modules
# under modules/). It edits no existing file. The guard at the end fails if any
# tracked file changed, which keeps the restored call UI (avatar, squircle) and
# every non-calling feature byte-identical. Wiring the existing call screen to
# js/olcall.ts is the one manual step (ios/README.md §Wire the call screen).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
app="${1:?usage: install-into-ol-app.sh <ol-ios-app> <TgVoipWebrtc.xcframework>}"
xcf="${2:?path to TgVoipWebrtc.xcframework (from //OLTgVoipXCFramework:TgVoipWebrtc)}"
test -f "$app/package.json" || { echo "not an Expo app: $app"; exit 1; }
test -d "$xcf" || { echo "no xcframework at $xcf"; exit 1; }
git -C "$app" diff --quiet && git -C "$app" diff --cached --quiet || { echo "app clone has uncommitted changes; commit or stash first"; exit 1; }

dst="$app/modules/openlounge-olcall"
rm -rf "$dst"
mkdir -p "$dst/Frameworks" "$dst/audio/core" "$dst/tgcalls-swift"
cp -R "$here/OpenLoungeCalls/Sources" "$here/OpenLoungeCalls/js" "$here/OpenLoungeCalls/modules" "$dst/"
rm -f "$dst/Sources/OLCallQueue.swift"   # moved to OLTgcallsSwift (stub left in this package)
cp "$here/OpenLoungeCalls/OpenLoungeOlcall.podspec" "$here/OpenLoungeCalls/expo-module.config.json" "$dst/"
cp "$root/audio/core/ol_audio.h" "$root/audio/core/ol_session_policy.c" "$dst/audio/core/"
cp "$here"/OLTgcallsSwift/Sources/OLTgcalls/*.swift "$dst/tgcalls-swift/"
cp -R "$xcf" "$dst/Frameworks/TgVoipWebrtc.xcframework"
# Module map for TgVoipWebrtc: prefer the one inside the xcframework slices.
if find "$dst/Frameworks/TgVoipWebrtc.xcframework" -name module.modulemap | grep -q .; then
  rm -rf "$dst/modules/TgVoipWebrtc"
else
  mkdir -p "$dst/modules/TgVoipWebrtc/TgVoipWebrtc"
  hdrs="$(find "$dst/Frameworks/TgVoipWebrtc.xcframework" -path '*Headers*' -name 'OngoingCallThreadLocalContext.h' | head -n1)"
  test -n "$hdrs" || { echo "xcframework has no OngoingCallThreadLocalContext.h"; exit 1; }
  cp "$(dirname "$hdrs")"/*.h "$dst/modules/TgVoipWebrtc/TgVoipWebrtc/"
fi
cat > "$dst/package.json" <<'EOF'
{
  "name": "openlounge-olcall",
  "version": "1.0.0",
  "main": "js/olcall.ts",
  "private": true
}
EOF

# Guard: nothing tracked changed (only the new untracked module dir).
if ! git -C "$app" diff --quiet; then
  echo "tracked files changed - refusing:"; git -C "$app" diff --stat; exit 1
fi
echo "added $dst (untracked). Next: wire the existing call screen (ios/README.md), then npx expo prebuild --platform ios"
