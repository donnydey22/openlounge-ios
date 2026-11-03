#!/bin/bash
# Dump XCTest failure messages + console from every result bundle the matrix produced (testVideoLeg/testAudioLeg).
mkdir -p xcr-out
for b in "$RUNNER_TEMP"/xcr/*.xcresult; do [ -e "$b" ] || continue; n=$(basename "$b" .xcresult)
  xcrun xcresulttool get test-results tests --path "$b" > xcr-out/$n.tests.json 2>/dev/null || true
  xcrun xcresulttool get log --type console --path "$b" > xcr-out/$n.console.txt 2>/dev/null || true
  echo "== $n"
  python3 - "xcr-out/$n.tests.json" <<'P' || true
import json,sys
def w(n,d=0):
  if n.get("result")=="Failed" or n.get("nodeType")=="Failure Message": print("  "*d+n.get("nodeType","")+": "+n.get("name",""))
  for c in n.get("children",[]): w(c,d+1)
for t in json.load(open(sys.argv[1])).get("testNodes",[]): w(t)
P
  grep -iE "error|fail|videoError|hardware|VT" xcr-out/$n.console.txt | head -20
done
grep -E "error:|XCTAssert|failed|Skipped" xt.log | head -60 || true
