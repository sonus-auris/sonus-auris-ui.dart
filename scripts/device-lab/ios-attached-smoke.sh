#!/usr/bin/env bash
# Bounded, non-destructive Flutter launch/relaunch smoke for a paired physical
# iPhone. Requires the operator's normal Apple development signing setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEVICE_ID="${1:-${IOS_DEVICE_ID:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-device-$STAMP}"
READY_HOLD_SECONDS="${SONUS_IOS_READY_HOLD_SECONDS:-12}"
RUN_TIMEOUT_SECONDS="${SONUS_IOS_RUN_TIMEOUT_SECONDS:-240}"
LAUNCH_CYCLES="${SONUS_IOS_LAUNCH_CYCLES:-2}"
EVIDENCE_POLICY="$ROOT/scripts/device-lab/evidence-policy.py"
CYCLE_MONITOR="$ROOT/scripts/device-lab/flutter-run-cycle.py"
mkdir -p "$EVIDENCE_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Required command is missing: python3" >&2
  exit 2
fi
if [[ ! -f "$EVIDENCE_POLICY" || ! -f "$CYCLE_MONITOR" ]]; then
  echo "Physical-iPhone device-lab helpers are missing." >&2
  exit 2
fi

# Use the shared policy for the complete shell transcript rather than carrying a
# second, drifting set of token and account-path expressions in this harness.
exec > >(python3 "$EVIDENCE_POLICY" --stream | tee "$EVIDENCE_DIR/run.log") 2>&1

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

need flutter
need python3
need tee

if [[ ! "$READY_HOLD_SECONDS" =~ ^[0-9]+$ ]] || (( READY_HOLD_SECONDS < 1 || READY_HOLD_SECONDS > 120 )); then
  echo "SONUS_IOS_READY_HOLD_SECONDS must be an integer from 1 through 120." >&2
  exit 2
fi
if [[ ! "$RUN_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( RUN_TIMEOUT_SECONDS < 60 || RUN_TIMEOUT_SECONDS > 900 )); then
  echo "SONUS_IOS_RUN_TIMEOUT_SECONDS must be an integer from 60 through 900." >&2
  exit 2
fi
if [[ ! "$LAUNCH_CYCLES" =~ ^[0-9]+$ ]] || (( LAUNCH_CYCLES < 1 || LAUNCH_CYCLES > 3 )); then
  echo "SONUS_IOS_LAUNCH_CYCLES must be an integer from 1 through 3." >&2
  exit 2
fi

flutter_devices_json="$(flutter devices --machine 2>/dev/null || true)"
if [[ -z "$DEVICE_ID" ]]; then
  selection="$(printf '%s' "$flutter_devices_json" | python3 -c '
import json
import sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
physical = []
for device in devices:
    target = str(device.get("targetPlatform", "")).lower()
    platform = str(device.get("platform", "")).lower()
    if device.get("emulator"):
        continue
    if target.startswith("ios") or platform.startswith("ios"):
        physical.append(str(device.get("id", "")))
print("\n".join(value for value in physical if value))
')"
  device_count="$(printf '%s\n' "$selection" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "$device_count" == "1" ]]; then
    DEVICE_ID="$selection"
  elif [[ "$device_count" -gt 1 ]]; then
    echo "More than one physical iPhone is visible. Pass the intended Flutter device ID or set IOS_DEVICE_ID." >&2
    exit 78
  fi
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No paired physical iPhone is visible to Flutter." >&2
  cat <<'NOTICE' >&2
Connect the iPhone by USB for first pairing, unlock it, tap Trust, enable
Developer Mode, and open Xcode > Window > Devices and Simulators until the
phone is shown as ready. Wi-Fi deployment works after the Mac and iPhone are
paired, but USB is the most reliable first-run transport.
NOTICE
  exit 78
fi

# Validate explicit IDs too. A simulator, stale ID, Android device, or macOS
# desktop target must never produce evidence labelled as a physical iPhone.
if ! printf '%s' "$flutter_devices_json" | IOS_DEVICE_ID="$DEVICE_ID" python3 -c '
import hashlib
import json
import os
import sys
try:
    devices = json.load(sys.stdin)
except Exception:
    raise SystemExit("Flutter device discovery did not return valid JSON")
needle = os.environ["IOS_DEVICE_ID"]
selected = next((d for d in devices if d.get("id") == needle), None)
if selected is None:
    raise SystemExit("The requested Flutter target is not currently visible")
target = str(selected.get("targetPlatform", "")).lower()
platform = str(selected.get("platform", "")).lower()
if selected.get("emulator"):
    raise SystemExit("The requested Flutter target is an emulator, not a physical iPhone")
if not (target.startswith("ios") or platform.startswith("ios")):
    raise SystemExit("The requested Flutter target is not an iOS device")
connection = selected.get("connectionInterface", selected.get("connection-interface", "unknown"))
print("target_fingerprint=" + hashlib.sha256(needle.encode()).hexdigest()[:12])
print("device_class=physical-iPhone")
print("platform=" + str(selected.get("platform", "ios")))
print("target_platform=" + str(selected.get("targetPlatform", "ios")))
print("connection_interface=" + str(connection))
print("emulator=false")
' > "$EVIDENCE_DIR/device.txt"; then
  echo "The selected Flutter target is not an eligible paired physical iPhone." >&2
  exit 78
fi

(
  cd "$ROOT"
  flutter pub get
)

cat > "$EVIDENCE_DIR/scope.txt" <<SCOPE
install_mode=flutter-debug-development-signing
app_data_cleared=false
device_reset=false
permissions_mutated=false
recording_automated=false
launch_cycles_requested=$LAUNCH_CYCLES
terminal_output_drain_required=true
fatal_runtime_markers_checked=true
SCOPE

run_launch_cycle() {
  local cycle="$1"
  local label
  local report
  local log
  local statuses
  if [[ "$cycle" == "1" ]]; then
    label="first-launch"
  else
    label="cold-relaunch-$cycle"
  fi
  report="$EVIDENCE_DIR/$label-cycle.json"
  log="$EVIDENCE_DIR/$label-flutter-run.txt"

  echo "== physical iPhone $label =="
  set +e
  (
    cd "$ROOT"
    python3 "$CYCLE_MONITOR" \
      --report "$report" \
      --timeout-seconds "$RUN_TIMEOUT_SECONDS" \
      --ready-hold-seconds "$READY_HOLD_SECONDS" \
      -- \
      flutter run \
      -d "$DEVICE_ID" \
      --debug \
      --device-timeout 60 \
      -t lib/main.dart \
      --dart-define=SONUS_BACKEND_BASE_URL=https://ci.invalid \
      --dart-define=SONUS_SUPABASE_URL=https://ci.supabase.co \
      --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_physical_device_lab \
      2>&1
  ) | python3 "$EVIDENCE_POLICY" --stream | tee "$log"
  statuses=("${PIPESTATUS[@]}")
  set -e

  if (( statuses[0] != 0 || statuses[1] != 0 || statuses[2] != 0 )); then
    echo "$label failed: monitor=${statuses[0]} sanitizer=${statuses[1]} evidence=${statuses[2]}" >&2
    return 1
  fi

  python3 - "$report" <<'PY'
import json
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["schema"] == "sonus-auris-flutter-run-cycle/v1"
assert report["status"] == "passed"
assert report["ready_observed"] is True
assert report["ready_hold_completed"] is True
assert report["quit_sent"] is True
assert report["terminal_output_drained"] is True
assert report["fatal_markers"] == []
assert report["monitor_errors"] == []
assert report["return_code"] == 0
PY
}

completed=0
for ((cycle = 1; cycle <= LAUNCH_CYCLES; cycle++)); do
  run_launch_cycle "$cycle"
  completed=$cycle
  if (( cycle < LAUNCH_CYCLES )); then
    sleep 2
  fi
done

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=physical-iphone-development-signed-install-and-bounded-relaunch
app_data_cleared=false
permissions_mutated=false
recording_automated=false
launch_cycles_completed=$completed
terminal_output_drained=true
fatal_runtime_markers_checked=true
shared_evidence_policy_stream=true
RESULT

echo "PHYSICAL IOS LAUNCH/RELAUNCH SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
