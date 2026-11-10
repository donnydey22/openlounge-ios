#!/usr/bin/env bash
# HARD build gate: exactly TWO files may touch AVAudioSession directly, each in its own scope. No skip flag, no env
# override, no other allowlist. Exit 1 = build fails. See ARCHITECTURE.md.
#   1. OLCALL_OWNER — tgcalls-swift OLCallAudioDevice (Telegram SharedCallAudioDevice ADM): the session owner DURING
#      olcall calls (setupAudioSession before the CallKit action is fulfilled, CallKit activation, route, reset).
#   2. OWNER — OLAudioSessionOwner: the session owner OUTSIDE calls (rooms / voice notes / ambient). Scoped: every
#      function in it that mutates the session must start its body with `guard !olcallOwnsSession`, so it can never
#      touch the session while an olcall call holds it (checked per function below).
set -euo pipefail
cd "$(dirname "$0")/.."
OWNER='modules/openlounge-calls/ios/OLAudioSessionOwner.swift'
OLCALL_OWNER='modules/openlounge-olcall/ios/tgcalls-swift/OLCallAudioDevice.swift'
for f in "$OWNER" "$OLCALL_OWNER"; do [ -f "$f" ] || { echo "FAIL: $f missing"; exit 1; }; done
# direct session access or any mutator / activation / configuration call
PAT='AVAudioSession\.sharedInstance|\[AVAudioSession[[:space:]]+sharedInstance\]|\.setActive\(|setActive:|\.setCategory\(|setCategory:|\.setMode\(|setMode:|overrideOutputAudioPort|setPreferredInput|setPreferredSampleRate|setPreferredIOBufferDuration|setPreferredInputNumberOfChannels|setPreferredOutputNumberOfChannels|setAggregatedIOPreference|setAllowHapticsAndSystemSoundsDuringRecording|setPrefersNoInterruptionsFromSystemAlerts|setInputGain|setInputDataSource|setOutputDataSource|setPreferredDataSource|requestRecordPermission|automaticallyConfiguresApplicationAudioSession[[:space:]]*=[[:space:]]*true|usesApplicationAudioSession[[:space:]]*=[[:space:]]*false'
# TgVoipWebrtc.xcframework = Telegram's prebuilt engine binary + headers (CI unpacks it; never committed).
hits=$(grep -rnE "$PAT" . \
  --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' --include='*.c' --include='*.cpp' \
  --exclude-dir=node_modules --exclude-dir=Pods --exclude-dir=.git --exclude-dir=build --exclude-dir=DerivedData --exclude-dir=pjinclude --exclude-dir=pjproject.xcframework --exclude-dir=TgVoipWebrtc.xcframework \
  | grep -v "^\./${OWNER}:" | grep -v "^\./${OLCALL_OWNER}:" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$hits" ]; then
  echo "FAIL: direct AVAudioSession use outside the two owners ($OLCALL_OWNER during olcall calls, $OWNER outside calls):"; echo "$hits"; exit 1
fi
# Scope of OWNER: each func containing a mutator must contain `guard !olcallOwnsSession` (olcall owns calls).
MUT='[.]setActive[(]|[.]setCategory[(]|[.]setMode[(]|overrideOutputAudioPort|setPreferredInput|setPreferredSampleRate|setPreferredIOBufferDuration|setPreferredInputNumberOfChannels|setPreferredOutputNumberOfChannels|setAggregatedIOPreference|setPrefersNoInterruptionsFromSystemAlerts|setInputGain|setInputDataSource|setOutputDataSource|setPreferredDataSource|requestRecordPermission'
unscoped=$(MUT="$MUT" awk '
  /^[[:space:]]*\/\// { next }
  /(^|[[:space:]])func[[:space:]]/ { if (fn != "" && m && !g) print fn; fn = $0; m = 0; g = 0 }
  fn != "" && $0 ~ ENVIRON["MUT"] { m = 1 }
  fn != "" && /guard[[:space:]]+!olcallOwnsSession/ { g = 1 }
  END { if (fn != "" && m && !g) print fn }' "$OWNER")
grep -qE 'var[[:space:]]+olcallOwnsSession' "$OWNER" || unscoped="${unscoped}
(missing olcallOwnsSession)"
if [ -n "$unscoped" ]; then
  echo "FAIL: $OWNER mutates AVAudioSession without 'guard !olcallOwnsSession' (olcall owns the session in calls):"; echo "$unscoped"; exit 1
fi
# One media engine: the old WebRTC.xcframework path (RTCAudioSession owner) must not come back.
web=$(grep -rnE '^[[:space:]]*(@_implementationOnly[[:space:]]+)?import[[:space:]]+WebRTC\b|RTCAudioSession' modules --include='*.swift' --include='*.m' --include='*.mm' --exclude-dir=Frameworks | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$web" ]; then echo "FAIL: old WebRTC.xcframework audio path reintroduced (olcall/tgcalls is the only engine):"; echo "$web"; exit 1; fi
# capture sessions must never configure the app audio session
cam=$(grep -rln 'AVCaptureSession()' modules --include='*.swift' || true)
for f in $cam; do grep -q 'automaticallyConfiguresApplicationAudioSession = false' "$f" || { echo "FAIL: $f creates AVCaptureSession without automaticallyConfiguresApplicationAudioSession = false"; exit 1; }; done
# signal-identical-calling: PJSIP sound-device path is deleted from calling; forbid its return anywhere in iOS modules.
pj=$(grep -rnE 'ol_pjsip_open_sound|ol_pjsip_close_sound|ensureSound\(|reopenSound\(|forceReactivateIfInactive|isOtherAudioPlaying' modules --include='*.swift' --include='*.c' --include='*.h' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$pj" ]; then echo "FAIL: removed PJSIP sound/activation middleman reintroduced:"; echo "$pj"; exit 1; fi
echo "OK: AVAudioSession is touched only by $OLCALL_OWNER (olcall calls) and $OWNER (outside calls, olcall-guarded)"
