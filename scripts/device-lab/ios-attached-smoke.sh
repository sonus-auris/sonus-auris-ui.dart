#!/usr/bin/env bash
# Bounded, non-destructive Flutter launch/relaunch smoke for a paired iPhone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEVICE_ID="${1:-${IOS_DEVICE_ID:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-device-$STAMP}"
READY_HOLD_SECONDS="${SONUS_IOS_READY_HOLD_SECONDS:-12}"
RUN_TIMEOUT_SECONDS="${SONUS_IOS_RUN_TIMEOUT_SECONDS:-240}"
QUIT_TIMEOUT_SECONDS="${SONUS_IOS_QUIT_TIMEOUT_SECONDS:-30}"
LAUNCH_CYCLES="${SONUS_IOS_LAUNCH_CYCLES:-2}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}
for command in flutter python3; do need "$command"; done

mkdir -p "$EVIDENCE_DIR"
exec > >(python3 "$ROOT/scripts/device-lab/evidence-policy.py" --stream \
  | tee "$EVIDENCE_DIR/run.log") 2>&1

validate_range() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < minimum || value > maximum )); then
    echo "$name must be an integer from $minimum through $maximum." >&2
    exit 2
  fi
}
validate_range SONUS_IOS_READY_HOLD_SECONDS "$READY_HOLD_SECONDS" 1 120
validate_range SONUS_IOS_RUN_TIMEOUT_SECONDS "$RUN_TIMEOUT_SECONDS" 60 900
validate_range SONUS_IOS_QUIT_TIMEOUT_SECONDS "$QUIT_TIMEOUT_SECONDS" 5 120
validate_range SONUS_IOS_LAUNCH_CYCLES "$LAUNCH_CYCLES" 1 3

flutter_devices_json="$(flutter devices --machine 2>/dev/null || true)"
if [[ -z "$DEVICE_ID" ]]; then
  selection="$(python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
physical = []
for device in devices:
    target = str(device.get("targetPlatform", "")).lower()
    platform = str(device.get("platform", "")).lower()
    if not device.get("emulator") and (target.startswith("ios") or platform.startswith("ios")):
        value = str(device.get("id", ""))
        if value:
            physical.append(value)
print("\n".join(physical))
' <<<"$flutter_devices_json")"
  device_count="$(sed '/^[[:space:]]*$/d' <<<"$selection" | wc -l | tr -d ' ')"
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
phone is ready. Wi-Fi deployment works after pairing; USB is the most reliable
first-run transport.
NOTICE
  exit 78
fi

if ! IOS_DEVICE_ID="$DEVICE_ID" python3 -c '
import hashlib, json, os, sys
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
' <<<"$flutter_devices_json" > "$EVIDENCE_DIR/device.txt"; then
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
controller=chunked-binary-stream
shared_evidence_policy=true
SCOPE

run_launch_cycle() {
  local cycle="${1:?cycle is required}" label
  if [[ "$cycle" == "1" ]]; then
    label="first-launch"
  else
    label="cold-relaunch-$cycle"
  fi
  echo "== physical iPhone $label =="
  (
    cd "$ROOT"
    python3 scripts/device-lab/flutter-run-controller.py \
      --policy scripts/device-lab/evidence-policy.py \
      --log "$EVIDENCE_DIR/$label-flutter-run.txt" \
      --timeout-seconds "$RUN_TIMEOUT_SECONDS" \
      --hold-seconds "$READY_HOLD_SECONDS" \
      --quit-timeout-seconds "$QUIT_TIMEOUT_SECONDS" \
      -- \
      flutter run \
        -d "$DEVICE_ID" \
        --debug \
        --device-timeout 60 \
        -t lib/main.dart \
        --dart-define=SONUS_BACKEND_BASE_URL=https://ci.invalid \
        --dart-define=SONUS_SUPABASE_URL=https://ci.supabase.co \
        --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_physical_device_lab
  )
}

completed=0
for ((cycle = 1; cycle <= LAUNCH_CYCLES; cycle++)); do
  run_launch_cycle "$cycle"
  completed=$cycle
  if (( cycle < LAUNCH_CYCLES )); then sleep 2; fi
done

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=physical-iphone-development-signed-install-and-bounded-relaunch
app_data_cleared=false
permissions_mutated=false
recording_automated=false
launch_cycles_completed=$completed
chunked_log_drain=true
readiness_hold_completed=true
shared_evidence_policy=true
RESULT

echo "PHYSICAL IOS LAUNCH/RELAUNCH SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
