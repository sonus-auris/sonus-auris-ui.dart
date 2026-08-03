#!/usr/bin/env bash
# Run the existing non-destructive iOS Simulator lifecycle smoke, then scan the
# complete session log stream while retaining only bounded, sanitized evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
UDID="${1:-${IOS_SIMULATOR_UDID:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-simulator-full-log-$STAMP}"
MAX_LOG_BYTES="${SONUS_DEVICE_LAB_MAX_LOG_BYTES:-524288}"
LOG_REPORT="$EVIDENCE_DIR/full-session-log-scan.json"
LOG_EVIDENCE="$EVIDENCE_DIR/full-session-simulator.log"
mkdir -p "$EVIDENCE_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

for command in xcrun python3 bash; do
  need "$command"
done

simulator_json="$(xcrun simctl list devices available --json)"
if [[ -z "$UDID" ]]; then
  UDID="$(printf '%s' "$simulator_json" | python3 -c '
import json
import sys
payload = json.load(sys.stdin)
booted = []
available = []
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        if "iPhone" not in device.get("name", ""):
            continue
        target = device.get("udid", "")
        if device.get("state") == "Booted":
            booted.append(target)
        else:
            available.append(target)
choices = booted or available
if choices:
    print(choices[0])
')"
fi
if [[ -z "$UDID" ]]; then
  echo "No available iPhone Simulator target was found." >&2
  exit 3
fi

# Verify the explicit target against the current simulator inventory without
# retaining its raw UDID in shareable evidence.
printf '%s' "$simulator_json" | SIM_UDID="$UDID" python3 -c '
import json
import os
import sys
payload = json.load(sys.stdin)
udid = os.environ["SIM_UDID"]
for devices in payload.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == udid and device.get("isAvailable", True):
            if "iPhone" not in device.get("name", ""):
                raise SystemExit("selected simulator is not an iPhone")
            raise SystemExit(0)
raise SystemExit("selected iPhone Simulator is not available")
'

LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
child_status=0
set +e
SONUS_DEVICE_LAB_DIR="$EVIDENCE_DIR" \
  bash "$ROOT/scripts/device-lab/ios-simulator-smoke.sh" "$UDID"
child_status=$?
set -e

predicate='process == "Runner" OR subsystem BEGINSWITH "app.sonusauris"'
pipeline_status=0
set +e
xcrun simctl spawn "$UDID" log show \
  --start "$LOG_START" \
  --style compact \
  --predicate "$predicate" \
  2>/dev/null \
  | python3 "$ROOT/scripts/device-lab/evidence-policy.py" --stream \
  | python3 "$ROOT/scripts/device-lab/bounded-log-scan.py" \
      --max-bytes "$MAX_LOG_BYTES" \
      --report "$LOG_REPORT" \
      --scan 'uncaught=Terminating app due to uncaught exception' \
      --scan 'fatal=Fatal error' \
      --scan 'exception=Unhandled Exception' \
      --scan 'exc-crash=EXC_CRASH' \
      --scan 'sigabrt=SIGABRT' \
      --scan 'lost-device=Lost connection to device' \
      --scan 'dyld=Library not loaded|dyld.*Reason' \
      > "$LOG_EVIDENCE"
pipeline_status=$?
set -e

if [[ "$pipeline_status" != "0" ]]; then
  echo "The full-session simulator log pipeline failed with status $pipeline_status." >&2
  exit 4
fi

python3 - "$LOG_REPORT" <<'PY'
import json
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["schema"] == "sonus-auris-bounded-log-scan/v1"
assert report["full_stream_scanned"] is True
assert report["output_bytes"] <= report["max_bytes"]
if report["matches_total"]:
    names = [item["name"] for item in report["patterns"] if item["matches"]]
    raise SystemExit("fatal simulator log patterns found: " + ", ".join(names))
PY

cat > "$EVIDENCE_DIR/full-session-log-audit.txt" <<AUDIT
status=passed
full_log_stream_scanned=true
startup_log_context_preserved=true
terminal_log_context_preserved=true
retained_log_max_bytes=$MAX_LOG_BYTES
fatal_patterns_present=false
raw_log_unbounded=false
AUDIT

if [[ -f "$EVIDENCE_DIR/result.txt" ]]; then
  cat >> "$EVIDENCE_DIR/result.txt" <<RESULT
full_log_stream_scanned=true
startup_log_context_preserved=true
terminal_log_context_preserved=true
retained_log_max_bytes=$MAX_LOG_BYTES
RESULT
fi

if [[ "$child_status" != "0" ]]; then
  echo "The underlying iOS Simulator lifecycle smoke failed with status $child_status; full-session logs were still audited." >&2
  exit "$child_status"
fi

echo "IOS SIMULATOR FULL-LOG SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
