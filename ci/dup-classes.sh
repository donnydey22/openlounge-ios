#!/usr/bin/env bash
# Counts Objective-C classes defined in more than one Mach-O image of a built .app
# (main executable + every embedded framework/dylib). Prints the count; exits 1 if > 0
# or if the app embeds any dynamic framework (the engine links statically, so there must be none).
set -euo pipefail
app="${1:?usage: dup-classes.sh <path/to/OpenLounge.app>}"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 2; }
fw=$(find "$app" -name '*.framework' -type d | wc -l | tr -d ' ')
find "$app" -name '*.framework' -type d
[ "$fw" -eq 0 ] || { echo "FAIL: $fw embedded framework(s)" >&2; exit 1; }
tmp="$(mktemp -d)"
images=0
while IFS= read -r f; do
  if file "$f" | grep -q 'Mach-O'; then
    images=$((images + 1))
    nm -gjU "$f" 2>/dev/null | sed -n 's/^_OBJC_CLASS_\$_//p' | sort -u > "$tmp/$images.txt"
  fi
done < <(find "$app" -type f \( -perm -u+x -o -name '*.dylib' \))
total=$(cat "$tmp"/*.txt 2>/dev/null | wc -l | tr -d ' ')
dups=$(cat "$tmp"/*.txt 2>/dev/null | sort | uniq -d | wc -l | tr -d ' ')
rtc=$(cat "$tmp"/*.txt 2>/dev/null | grep -c '^RTC' || true)
echo "dup-classes: app=$(basename "$app") embedded_frameworks=$fw images=$images objc_classes=$total rtc_classes=$rtc duplicate_classes=$dups"
cat "$tmp"/*.txt 2>/dev/null | sort | uniq -d | head -n 60
rm -rf "$tmp"
[ "$dups" -eq 0 ] || { echo "FAIL: duplicate Objective-C classes" >&2; exit 1; }
