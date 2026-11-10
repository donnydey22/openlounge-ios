#!/usr/bin/env bash
# Signed ad hoc IPA with the existing Open Lounge Apple Distribution certificate and ad hoc profile
# (team 9A6NA2ZAFH, bundle com.donnydey.openlounge). Run after ci/build.sh on the same checkout.
# Env: P12_B64 P12_PASSWORD PROFILE_B64 ARTIFACT_PASSPHRASE. Output: out/OpenLounge.ipa.enc (+ .sha256, SIGNING.txt).
# Nothing is created on the Apple account; the certificate and profile are only read.
set -euo pipefail
: "${P12_B64:?}" "${P12_PASSWORD:?}" "${PROFILE_B64:?}" "${ARTIFACT_PASSPHRASE:?}"
root="$(cd "$(dirname "$0")/.." && pwd)"; cd "$root"
tmp="${RUNNER_TEMP:-$(mktemp -d)}/olsign"; rm -rf "$tmp"; mkdir -p "$tmp" out
kc="$tmp/ol-sign.keychain-db"; kcpass="$(uuidgen)"
cleanup() { security delete-keychain "$kc" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

security create-keychain -p "$kcpass" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$kcpass" "$kc"
printf '%s' "$P12_B64" | base64 --decode > "$tmp/dist.p12"
security import "$tmp/dist.p12" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$kc" >/dev/null
rm -f "$tmp/dist.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
ident="$(security find-identity -v -p codesigning "$kc" | sed -n 's/.*"\(Apple Distribution[^"]*\)".*/\1/p' | head -n1)"
[ -n "$ident" ] || { echo "FAIL: no Apple Distribution identity in the p12" >&2; exit 1; }

printf '%s' "$PROFILE_B64" | base64 --decode > "$tmp/adhoc.mobileprovision"
security cms -D -i "$tmp/adhoc.mobileprovision" > "$tmp/profile.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$tmp/profile.plist"; }
uuid="$(pb UUID)"; pname="$(pb Name)"; appid="$(pb Entitlements:application-identifier)"
devices="$(pb ProvisionedDevices | grep -c -E '^ +[0-9A-Fa-f-]{20,}$' || true)"
[ "$appid" = "9A6NA2ZAFH.com.donnydey.openlounge" ] || { echo "FAIL: profile is for $appid" >&2; exit 1; }
for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$d"; cp "$tmp/adhoc.mobileprovision" "$d/$uuid.mobileprovision"
done
echo "identity: $ident | profile: $pname ($uuid) devices=$devices"

rm -rf build/OpenLounge.xcarchive build/export
xcodebuild archive -project OpenLounge.xcodeproj -scheme OpenLounge -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/OpenLounge.xcarchive -derivedDataPath build/dd-archive \
  OL_SIGNING_ALLOWED=YES OL_PROFILE="$uuid" OL_SIGN_IDENTITY="$ident" OTHER_CODE_SIGN_FLAGS="--keychain $kc"

cat > "$tmp/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>release-testing</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>9A6NA2ZAFH</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>com.donnydey.openlounge</key><string>$uuid</string></dict>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/OpenLounge.xcarchive -exportOptionsPlist "$tmp/ExportOptions.plist" -exportPath build/export
ipa="$(find build/export -name '*.ipa' | head -n1)"
[ -f "$ipa" ] || { echo "FAIL: no IPA exported" >&2; exit 1; }

# Verify what was signed.
x="$tmp/x"; mkdir -p "$x"; (cd "$x" && unzip -q "$root/$ipa")
app="$(find "$x/Payload" -maxdepth 1 -name '*.app' | head -n1)"
codesign --verify --deep --strict "$app"
security cms -D -i "$app/embedded.mobileprovision" > "$tmp/embedded.plist"
{
  echo "ipa: openlounge-ios-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")-b$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist").ipa"
  echo "bundle: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  codesign -dvv "$app" 2>&1 | grep -E '^(Authority=Apple Distribution|TeamIdentifier)'
  echo "profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$tmp/embedded.plist") $(/usr/libexec/PlistBuddy -c 'Print :UUID' "$tmp/embedded.plist") devices=$devices"
  echo "expires: $(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$tmp/embedded.plist")"
  echo "get-task-allow: $(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -extract get-task-allow raw - 2>/dev/null || echo absent)"
  echo "NSMicrophoneUsageDescription: $(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$app/Info.plist")"
  echo "NSCameraUsageDescription: $(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$app/Info.plist")"
  echo "aps-environment: $(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -extract aps-environment raw - 2>/dev/null || echo absent)"
  echo "UIBackgroundModes: $(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$app/Info.plist" | tr -d '\n' | tr -s ' ')"
  bash "$root/ci/dup-classes.sh" "$app" | head -n1
  echo "sha256: $(shasum -a 256 "$ipa" | cut -d' ' -f1)"
  echo "size: $(stat -f%z "$ipa")"
} | tee out/SIGNING.txt
grep -q 00008110-000E7DD63C03801E "$tmp/embedded.plist" && echo "Donny's iPhone is in the profile" | tee -a out/SIGNING.txt || echo "WARNING: Donny's iPhone UDID not in profile" | tee -a out/SIGNING.txt
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$ipa" -out out/OpenLounge.ipa.enc -pass env:ARTIFACT_PASSPHRASE
shasum -a 256 "$ipa" | cut -d' ' -f1 > out/OpenLounge.ipa.sha256
rm -f "$ipa"
echo "PASS: signed ad hoc IPA (encrypted) in out/"
