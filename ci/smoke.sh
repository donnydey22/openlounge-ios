#!/usr/bin/env bash
# Launch smoke test for the Open Lounge simulator app (macOS + Xcode only).
#   ci/smoke.sh <OpenLounge.app> <out-dir> <runtime> [<runtime> ...]
# <runtime> is an iOS version such as 27.0, 26.5, 18.5, 17.5. A trailing "?" makes it optional: if the runtime
# is not installed the script tries `xcodebuild -downloadPlatform`, and a runtime that is still missing is reported
# UNAVAILABLE without failing. A required runtime that is missing fails.
# Env:
#   SMOKE_DEVICE   preferred simulator device name (e.g. "iPhone 17 Pro"). Foldable "iPhone Duo" is never preferred.
#   SMOKE_ATTEMPTS clean boot+launch retries (default 3). Each attempt deletes the sim and boots fresh.
# Per runtime, a pass requires:
#   - the app process alive for 20 s without restarting, and no crash report,
#   - no fatal UIScene message, and on iOS 27+ no "does not adopt UIScene" message,
#   - a screenshot of the dark sign-in page (not a blank launch screen, not SpringBoard).
# Writes <out-dir>/smoke-<runtime>.{png,log,json} and <out-dir>/smoke-summary.txt. Exit 0 only if every runtime passed.
set -uo pipefail
[ "$(uname -s)" = Darwin ] || { echo "BLOCKED: macOS + Xcode only" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:?usage: ci/smoke.sh <OpenLounge.app> <out-dir> <runtime>...}"; out="${2:?}"; shift 2
[ -d "$app" ] || { echo "FAIL: no app at $app" >&2; exit 2; }
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
bid=com.donnydey.openlounge
mkdir -p "$out"; out="$(cd "$out" && pwd)"; summary="$out/smoke-summary.txt"; : > "$summary"
overall=0
attempts="${SMOKE_ATTEMPTS:-3}"

is_foldable() { case "$1" in *"Duo"*|*"iPhone 19"*) return 0;; *) return 1;; esac; }

# Print "runtime-id|version" lines, preferring a generic iOS-N-N runtime over a device-locked one (iPhone19-4).
list_runtimes() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
want = sys.argv[1]
rows = []
for r in json.load(sys.stdin)["runtimes"]:
    v = r.get("version", "")
    if not r.get("isAvailable", False) or "iOS" not in r.get("name", r.get("identifier", "")): continue
    if v != want and not v.startswith(want + "."): continue
    ident = r["identifier"]
    # Prefer the generic com.apple.CoreSimulator.SimRuntime.iOS-27-2 over ...-iPhone19-4.
    score = 0 if ident.split(".")[-1].startswith("iOS-") and "iPhone" not in ident else 1
    names = [d["name"] for d in r.get("supportedDeviceTypes", []) if "iPhone" in d.get("name","")]
    rows.append((score, ident, v, names))
rows.sort()
for score, ident, v, names in rows:
    print("%s|%s|%s" % (ident, v, ",".join(names)))
' "$1"
}

preferred_devices() {
  # Standard bar/iphone models first. Duo/foldable last, and only as a last resort.
  echo "${SMOKE_DEVICE:-}"
  echo "iPhone 17 Pro"
  echo "iPhone 16 Pro"
  echo "iPhone 15 Pro"
  echo "iPhone 14 Pro"
  echo "iPhone 17"
  echo "iPhone 16"
  echo "iPhone 15"
  echo "iPhone 14"
}

# Try to create a standard (non-Duo) iPhone on runtime $1. Prints "udid|device-name" or empty.
create_phone() {
  local rid="$1" label="$2" name udid
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    is_foldable "$name" && continue
    udid="$(xcrun simctl create "ol-smoke-$label" "$name" "$rid" 2>>"$log")" || continue
    echo "$udid|$name"; return 0
  done < <(preferred_devices)
  # Last resort: first supported iPhone that is not a Duo.
  xcrun simctl list devicetypes -j | python3 -c '
import json,sys
rid=sys.argv[1]
# no-op placeholder
' >/dev/null 2>&1
  return 1
}

download_runtime() {
  local rt="$1"
  echo "iOS $rt not usable/installed; trying xcodebuild -downloadPlatform" | tee -a "$log"
  ( xcodebuild -downloadPlatform iOS -buildVersion "$rt" >"$out/download-$rt.log" 2>&1 ) & local dl=$!
  ( sleep 1500; kill "$dl" 2>/dev/null ) & local wd=$!
  wait "$dl" 2>/dev/null; kill "$wd" 2>/dev/null
  tail -n 5 "$out/download-$rt.log" 2>/dev/null
}

drawn() { awk -v d="$1" -v n="$2" -v k="${3:-0}" 'BEGIN{exit !(d>=40 && n>=0.02 && k>=0.35)}'; }

# Take a screenshot of $udid into $dest; tries default display, then every id from enumerate / error text.
take_shot() {
  local udid="$1" dest="$2" err tmp ids id
  tmp="$(mktemp)"
  if xcrun simctl io "$udid" screenshot "$dest" >"$tmp" 2>&1; then cat "$tmp" >>"$log"; rm -f "$tmp"; return 0; fi
  cat "$tmp" >>"$log"
  ids="$(grep -o -E -- '--display=[^ ]+' "$tmp" | sed 's/--display=//' | tr '\n' ' ')"
  xcrun simctl io "$udid" enumerate >>"$log" 2>&1 || true
  [ -n "$ids" ] || ids="internal external 1 2 3"
  for id in $ids; do
    if xcrun simctl io "$udid" screenshot --display="$id" "$dest" >>"$log" 2>&1; then rm -f "$tmp"; return 0; fi
  done
  rm -f "$tmp"; return 1
}

pid_of() {
  xcrun simctl spawn "$1" launchctl list 2>/dev/null | awk -v b="UIKitApplication:$bid" 'index($0,b){print $1; exit}'
}

boot_clean() {
  local udid="$1" bootlog="$2"
  xcrun simctl boot "$udid" >>"$bootlog" 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >>"$bootlog" 2>&1
  needle=$(printf "%s%s" "Data Migrat" "ion Failed")
  if grep -q "$needle" "$bootlog"; then
    echo "boot ended with: $needle" | tee -a "$bootlog"
    return 1
  fi
  # Let SpringBoard settle before install/launch (helps freshly downloaded runtimes).
  sleep 8
  return 0
}

one() {
  local spec="$1" rt optional=0 log result reason="" rid full rows first
  rt="${spec%\?}"; [ "$rt" != "$spec" ] && optional=1
  echo "=== smoke iOS $rt"
  log="$out/smoke-$rt.log"; : > "$log"

  rows="$(list_runtimes "$rt")"
  if [ -z "$rows" ]; then
    if [ "$optional" = 1 ] || [ "${SMOKE_DOWNLOAD:-1}" = 1 ]; then
      download_runtime "$rt"
      rows="$(list_runtimes "$rt")"
    fi
  fi
  if [ -z "$rows" ]; then
    echo "iOS $rt: UNAVAILABLE"; echo "iOS $rt UNAVAILABLE$([ $optional = 1 ] && echo ' (optional)')" >> "$summary"
    printf '{"runtime":"%s","result":"UNAVAILABLE","optional":%s}\n' "$rt" "$([ $optional = 1 ] && echo true || echo false)" > "$out/smoke-$rt.json"
    [ "$optional" = 1 ] || overall=1; return
  fi
  echo "$rows" | tee -a "$log"

  local try=1 ok=0 udid="" dtname="" pid="" stats="" distinct=0 nondom=0 darkfrac=0 alive=0
  while [ "$try" -le "$attempts" ]; do
    echo "---- attempt $try/$attempts" | tee -a "$log"
    reason=""; alive=0; pid=""; stats=""; distinct=0; nondom=0; darkfrac=0
    # Prefer the first (generic) runtime that we can attach a standard iPhone to.
    udid=""; dtname=""; rid=""; full=""
    while IFS='|' read -r cand_rid cand_full cand_names; do
      [ -n "$cand_rid" ] || continue
      echo "trying runtime $cand_rid ($cand_full) supported=[$cand_names]" | tee -a "$log"
      local created
      created="$(create_phone "$cand_rid" "$rt")" || created=""
      if [ -n "$created" ]; then
        udid="${created%%|*}"; dtname="${created#*|}"; rid="$cand_rid"; full="$cand_full"
        break
      fi
      echo "could not create a standard iPhone on $cand_rid" | tee -a "$log"
    done <<EOFROWS
$rows
EOFROWS
    if [ -z "$udid" ]; then
      reason="no standard (non-Duo) iPhone could be created on any $rt runtime"
      echo "$reason" | tee -a "$log"
      try=$((try+1)); continue
    fi
    echo "created $dtname ($udid) on $rid" | tee -a "$log"
    if ! boot_clean "$udid" "$log"; then
      reason="simulator boot failed (data-migrator or bootstatus error)"
      xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1
      try=$((try+1)); continue
    fi
    if ! xcrun simctl install "$udid" "$app" >>"$log" 2>&1; then
      echo "install failed, retrying once after a restart" | tee -a "$log"
      xcrun simctl shutdown "$udid" >>"$log" 2>&1; sleep 5
      if ! boot_clean "$udid" "$log" || ! xcrun simctl install "$udid" "$app" >>"$log" 2>&1; then
        reason="install failed"; xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1
        try=$((try+1)); continue
      fi
    fi
    local marker lpid start cur shot8
    marker="$(mktemp)"
    script -q "$out/console-$rt.log" xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bid" >/dev/null 2>&1 &
    lpid=$!
    pid=""; for _ in $(seq 1 30); do
      pid="$(pid_of "$udid")"
      case "$pid" in ''|-) pid="";; *) break;; esac; sleep 1
    done
    if [ -z "$pid" ]; then
      reason="process never started"
      take_shot "$udid" "$out/smoke-$rt.png" || true
    else
      echo "launched pid $pid" | tee -a "$log"
      alive=1; start=$SECONDS; shot8=0
      while [ $((SECONDS - start)) -lt 20 ]; do
        sleep 1
        cur="$(pid_of "$udid")"
        if [ "$cur" != "$pid" ]; then reason="process gone or restarted after $((SECONDS - start)) s (was $pid, now ${cur:-none})"; alive=0; break; fi
        if [ $((SECONDS - start)) -ge 8 ] && [ "$shot8" = 0 ]; then take_shot "$udid" "$out/smoke-$rt-8s.png" || true; shot8=1; fi
      done
      take_shot "$udid" "$out/smoke-$rt.png" || true
      # If the process is alive but the first shot is not the sign-in page, wait longer for WKWebView and reshoot.
      if [ "$alive" = 1 ] && [ -f "$out/smoke-$rt.png" ]; then
        stats="$(python3 "$here/png-stats.py" "$out/smoke-$rt.png" 2>&1)"
        distinct="$(printf '%s' "$stats" | sed -n 's/.*distinct=\([0-9]*\).*/\1/p')"
        nondom="$(printf '%s' "$stats" | sed -n 's/.*nondominant=\([0-9.]*\).*/\1/p')"
        darkfrac="$(printf '%s' "$stats" | sed -n 's/.*darkfrac=\([0-9.]*\).*/\1/p')"
        if ! drawn "$distinct" "$nondom" "$darkfrac"; then
          echo "page not drawn yet ($stats); waiting 20 s more" | tee -a "$log"
          sleep 20
          cur="$(pid_of "$udid")"
          [ "$cur" = "$pid" ] || { reason="process gone during extra wait"; alive=0; }
          take_shot "$udid" "$out/smoke-$rt.png" || true
        fi
      fi
    fi
    kill "$lpid" 2>/dev/null
    sleep 2
    xcrun simctl spawn "$udid" log show --last 5m --style compact --predicate 'process == "OpenLounge" OR eventMessage CONTAINS[c] "UIScene"' > "$out/oslog-$rt.log" 2>&1 || true
    local fatal soft crash
    fatal="$(cat "$out/console-$rt.log" "$out/oslog-$rt.log" 2>/dev/null | grep -a -i -E "UIScene life ?cycle is required|requires the scene|scene-based life ?cycle is required" | head -n 3)"
    soft="$(cat "$out/console-$rt.log" "$out/oslog-$rt.log" 2>/dev/null | grep -a -i -E "does not adopt UIScene|UIScene lifecycle will soon be required" | head -n 1)"
    crash="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'OpenLounge*' -newer "$marker" 2>/dev/null | head -n 3)"
    rm -f "$marker"
    stats=""; distinct=0; nondom=0; darkfrac=0
    if [ -f "$out/smoke-$rt.png" ]; then stats="$(python3 "$here/png-stats.py" "$out/smoke-$rt.png" 2>&1)"; fi
    distinct="$(printf '%s' "$stats" | sed -n 's/.*distinct=\([0-9]*\).*/\1/p')"
    nondom="$(printf '%s' "$stats" | sed -n 's/.*nondominant=\([0-9.]*\).*/\1/p')"
    darkfrac="$(printf '%s' "$stats" | sed -n 's/.*darkfrac=\([0-9.]*\).*/\1/p')"
    echo "screenshot: ${stats:-none} alive=$alive pid=$pid device=$dtname" | tee -a "$log"
    result=FAIL
    if [ "$alive" = 1 ] && [ -z "$fatal" ] && [ -z "$crash" ]; then
      case "$rt" in 2[7-9].*|[3-9][0-9].*) [ -n "$soft" ] && reason="$reason; UIScene adoption message on iOS $rt: $soft";; esac
      case "$reason" in *"UIScene adoption"*) ;; *)
        if [ -n "$distinct" ] && drawn "$distinct" "$nondom" "$darkfrac"; then
          result=PASS; reason=""
        else
          reason="$reason; screenshot is not the sign-in page ($stats)"
        fi
      ;; esac
    else
      [ "$alive" = 1 ] || reason="${reason:-not alive}"
      [ -z "$fatal" ] || reason="$reason; fatal UIScene message: $fatal"
      [ -z "$crash" ] || reason="$reason; crash report: $crash"
    fi
    # Keep the sim around for the summary line, then delete.
    echo "attempt $try: $result${reason:+ - $reason} ($dtname)" | tee -a "$log"
    if [ "$result" = PASS ]; then
      ok=1
      xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1
      break
    fi
    xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1
    try=$((try+1))
  done

  if [ "$ok" = 1 ]; then result=PASS; else result=FAIL; [ -n "$reason" ] || reason="all $attempts attempts failed"; fi
  echo "iOS ${full:-$rt} (${dtname:-unknown}): $result${reason:+ - $reason}" | tee -a "$summary" "$log"
  printf '{"runtime":"%s","full":"%s","device":"%s","result":"%s","stats":"%s","attempts":%s}\n' "$rt" "${full:-}" "${dtname:-}" "$result" "${stats:-}" "$attempts" > "$out/smoke-$rt.json"
  [ "$result" = PASS ] || overall=1
}

for r in "$@"; do one "$r"; done
echo "---- smoke summary"; cat "$summary"
exit "$overall"
