#!/usr/bin/env bash
# HARD build gate: OLAudioSessionOwner.swift is the ONLY file allowed to touch AVAudioSession directly.
# No skip flag, no env override, no allowlist beyond that one file. Exit 1 = build fails. See ARCHITECTURE.md.
set -euo pipefail
cd "$(dirname "$0")/.."
OWNER='modules/openlounge-calls/ios/OLAudioSessionOwner.swift'
[ -f "$OWNER" ] || { echo "FAIL: $OWNER missing"; exit 1; }
# direct session access or any mutator / activation / configuration call
PAT='AVAudioSession\.sharedInstance|\[AVAudioSession[[:space:]]+sharedInstance\]|\.setActive\(|setActive:|\.setCategory\(|setCategory:|\.setMode\(|setMode:|overrideOutputAudioPort|setPreferredInput|setPreferredSampleRate|setPreferredIOBufferDuration|setPreferredInputNumberOfChannels|setPreferredOutputNumberOfChannels|setAggregatedIOPreference|setAllowHapticsAndSystemSoundsDuringRecording|setPrefersNoInterruptionsFromSystemAlerts|setInputGain|setInputDataSource|setOutputDataSource|setPreferredDataSource|requestRecordPermission|automaticallyConfiguresApplicationAudioSession[[:space:]]*=[[:space:]]*true|usesApplicationAudioSession[[:space:]]*=[[:space:]]*false'
hits=$(grep -rnE "$PAT" . \
  --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' --include='*.c' --include='*.cpp' \
  --exclude-dir=node_modules --exclude-dir=Pods --exclude-dir=.git --exclude-dir=build --exclude-dir=DerivedData --exclude-dir=pjinclude --exclude-dir=pjproject.xcframework --exclude-dir=WebRTC.xcframework \
  | grep -v "^\./${OWNER}:" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$hits" ]; then
  echo "FAIL: direct AVAudioSession use outside $OWNER (route it through OLAudioSessionOwner.shared):"; echo "$hits"; exit 1
fi
# capture sessions must never configure the app audio session
cam=$(grep -rln 'AVCaptureSession()' modules --include='*.swift' || true)
for f in $cam; do grep -q 'automaticallyConfiguresApplicationAudioSession = false' "$f" || { echo "FAIL: $f creates AVCaptureSession without automaticallyConfiguresApplicationAudioSession = false"; exit 1; }; done
# signal-identical-calling: PJSIP sound-device path is deleted from calling; forbid its return anywhere in iOS modules.
pj=$(grep -rnE 'ol_pjsip_open_sound|ol_pjsip_close_sound|ensureSound\(|reopenSound\(|forceReactivateIfInactive|isOtherAudioPlaying' modules --include='*.swift' --include='*.c' --include='*.h' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$pj" ]; then echo "FAIL: removed PJSIP sound/activation middleman reintroduced:"; echo "$pj"; exit 1; fi
echo "OK: AVAudioSession is touched only by $OWNER"
