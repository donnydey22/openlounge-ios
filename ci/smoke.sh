#!/usr/bin/env bash
# Launch smoke test for the Open Lounge simulator app (macOS + Xcode only).
#   ci/smoke.sh <OpenLounge.app> <out-dir> <runtime> [<runtime> ...]
# <runtime> is an iOS version such as 27.0, 26.5, 18.5, 17.5. A trailing "?" (16.4?) makes it optional: if the runtime
# is not installed the script tries `xcodebuild -downloadPlatform`, and a runtime that is still missing is reported
# UNAVAILABLE without failing. A required runtime that is missing fails.
# Per runtime: boot a fresh iPhone simulator, install, `simctl launch --console-pty`, then require
#   - the app process alive for 20 s without restarting, and no crash report,
#   - no fatal UIScene message ("UIScene life cycle is required ...") in the console or the unified log,
#     and, on iOS 27+, not even the soft "does not adopt UIScene" message (older runtimes only warn with it),
#   - a screenshot that shows a drawn page (more than a uniform launch screen).
# Writes <out-dir>/smoke-<runtime>.{png,log,json} and <out-dir>/smoke-summary.txt. Exit 0 only if every runtime passed.
set -uo pipefail
[ "$(uname -s)" = Darwin ] || { echo "BLOCKED: macOS + Xcode only" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:?usage: ci/smoke.sh <OpenLounge.app> <out-dir> <runtime>...}"; out="${2:?}"; shift 2
[ -d "$app" ] || { echo "FAIL: no app at $app" >&2; exit 2; }
bid=com.donnydey.openlounge
mkdir -p "$out"; summary="$out/smoke-summary.txt"; : > "$summary"
overall=0

pick() { # pick <version> -> "<runtime-id>|<devicetype-id>|<devicetype-name>|<full version>" or empty
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
want = sys.argv[1]
prefer = ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro", "iPhone 15", "iPhone 14 Pro", "iPhone 14"]
for r in json.load(sys.stdin)["runtimes"]:
    v = r.get("version", "")
    if not r.get("isAvailable", False) or "iOS" not in r.get("name", r.get("identifier", "")): continue
    if v != want and not v.startswith(want + "."): continue
    ph = [d for d in r.get("supportedDeviceTypes", []) if d.get("productFamily", "iPhone") == "iPhone" and "iPhone" in d["name"]]
    if not ph: continue
    ph.sort(key=lambda d: prefer.index(d["name"]) if d["name"] in prefer else 99)
    print("%s|%s|%s|%s" % (r["identifier"], ph[0]["identifier"], ph[0]["name"], v)); break
' "$1"
}

one() { # one <runtime-spec>
  local spec="$1" rt optional=0 sel rid dtid dtname full udid t0 pid cur start marker log result reason="" alive=1
  rt="${spec%\?}"; [ "$rt" != "$spec" ] && optional=1
  echo "=== smoke iOS $rt"
  sel="$(pick "$rt")"
  if [ -z "$sel" ] && [ "$optional" = 1 ]; then
    echo "iOS $rt not installed; trying xcodebuild -downloadPlatform"
    ( xcodebuild -downloadPlatform iOS -buildVersion "$rt" >"$out/download-$rt.log" 2>&1 ) & local dl=$!
    ( sleep 1500; kill "$dl" 2>/dev/null ) & local wd=$!
    wait "$dl" 2>/dev/null; kill "$wd" 2>/dev/null; tail -n 3 "$out/download-$rt.log" 2>/dev/null
    sel="$(pick "$rt")"
  fi
  if [ -z "$sel" ]; then
    echo "iOS $rt: UNAVAILABLE"; echo "iOS $rt UNAVAILABLE$([ $optional = 1 ] && echo ' (optional)')" >> "$summary"
    printf '{"runtime":"%s","result":"UNAVAILABLE","optional":%s}\n' "$rt" "$([ $optional = 1 ] && echo true || echo false)" > "$out/smoke-$rt.json"
    [ "$optional" = 1 ] || overall=1; return
  fi
  IFS='|' read -r rid dtid dtname full <<< "$sel"
  log="$out/smoke-$rt.log"; : > "$log"
  echo "runtime $full ($rid) device $dtname" | tee -a "$log"
  udid="$(xcrun simctl create "ol-smoke-$rt" "$dtid" "$rid")" || { echo "FAIL: simctl create" | tee -a "$log"; overall=1; return; }
  xcrun simctl boot "$udid" >>"$log" 2>&1; xcrun simctl bootstatus "$udid" -b >>"$log" 2>&1
  xcrun simctl install "$udid" "$app" >>"$log" 2>&1 || { reason="install failed"; alive=0; }
  marker="$(mktemp)"
  if [ "$alive" = 1 ]; then
    # --console-pty needs a tty: `script` supplies one.
    script -q "$out/console-$rt.log" xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bid" >/dev/null 2>&1 &
    local lpid=$!
    pid=""; for _ in $(seq 1 20); do
      pid="$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null | awk -v b="UIKitApplication:$bid" 'index($0,b){print $1; exit}')"
      case "$pid" in ''|-) pid="";; *) break;; esac; sleep 1
    done
    if [ -z "$pid" ]; then reason="process never started"; alive=0; else
      echo "launched pid $pid" | tee -a "$log"
      start=$SECONDS; shot8=0
      while [ $((SECONDS - start)) -lt 20 ]; do
        sleep 1
        cur="$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null | awk -v b="UIKitApplication:$bid" 'index($0,b){print $1; exit}')"
        if [ "$cur" != "$pid" ]; then reason="process gone or restarted after $((SECONDS - start)) s (was $pid, now ${cur:-none})"; alive=0; break; fi
        [ $((SECONDS - start)) -ge 8 ] && [ "$shot8" = 0 ] && { xcrun simctl io "$udid" screenshot "$out/smoke-$rt-8s.png" >>"$log" 2>&1; shot8=1; }
      done
    fi
    xcrun simctl io "$udid" screenshot "$out/smoke-$rt.png" >>"$log" 2>&1
    kill "$lpid" 2>/dev/null
  fi
  sleep 2
  xcrun simctl spawn "$udid" log show --last 5m --style compact --predicate 'process == "OpenLounge" OR eventMessage CONTAINS[c] "UIScene"' > "$out/oslog-$rt.log" 2>&1
  local fatal="" soft="" crash=""
  fatal="$(cat "$out/console-$rt.log" "$out/oslog-$rt.log" 2>/dev/null | grep -a -i -E "UIScene life ?cycle is required|requires the scene|scene-based life ?cycle is required" | head -n 3)"
  soft="$(cat "$out/console-$rt.log" "$out/oslog-$rt.log" 2>/dev/null | grep -a -i -E "does not adopt UIScene|UIScene lifecycle will soon be required" | head -n 1)"
  crash="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'OpenLounge*' -newer "$marker" 2>/dev/null | head -n 3)"
  rm -f "$marker"
  local stats="" distinct=0 nondom=0
  if [ -f "$out/smoke-$rt.png" ]; then stats="$(python3 "$here/png-stats.py" "$out/smoke-$rt.png" 2>&1)"; fi
  distinct="$(printf '%s' "$stats" | sed -n 's/.*distinct=\([0-9]*\).*/\1/p')"; nondom="$(printf '%s' "$stats" | sed -n 's/.*nondominant=\([0-9.]*\).*/\1/p')"
  echo "screenshot: ${stats:-none}" | tee -a "$log"
  result=PASS
  [ "$alive" = 1 ] || { result=FAIL; reason="${reason:-not alive}"; }
  [ -z "$fatal" ] || { result=FAIL; reason="$reason; fatal UIScene message: $fatal"; }
  [ -z "$crash" ] || { result=FAIL; reason="$reason; crash report: $crash"; }
  case "$rt" in 2[7-9].*|[3-9][0-9].*) [ -z "$soft" ] || { result=FAIL; reason="$reason; UIScene adoption message on iOS $rt: $soft"; };; esac
  if [ -n "$distinct" ]; then
    awk -v d="$distinct" -v n="$nondom" 'BEGIN{exit !(d>=40 && n>=0.02)}' || { result=FAIL; reason="$reason; screenshot looks blank/uniform ($stats)"; }
  else
    [ -s "$out/smoke-$rt.png" ] && [ "$(stat -f%z "$out/smoke-$rt.png")" -gt 30000 ] || { result=FAIL; reason="$reason; no usable screenshot"; }
  fi
  echo "iOS $full ($dtname): $result${reason:+ - $reason}${soft:+ [soft: $soft]}" | tee -a "$summary" "$log"
  printf '{"runtime":"%s","full":"%s","device":"%s","result":"%s","stats":"%s"}\n' "$rt" "$full" "$dtname" "$result" "$stats" > "$out/smoke-$rt.json"
  [ "$result" = PASS ] || overall=1
  xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1
}

for r in "$@"; do one "$r"; done
echo "---- smoke summary"; cat "$summary"
exit "$overall"
