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
mkdir -p "$EVIDENCE_DIR"

# The sanitizer is part of the evidence boundary, so verify it before opening
# the process-substitution stream rather than failing later with an unsanitized
# shell diagnostic.
if ! command -v python3 >/dev/null 2>&1; then
  echo "Required command is missing: python3" >&2
  exit 2
fi

# Sanitize the complete run, including Flutter pub/build/signing failures that
# can contain a local username, account email, callback URL, or VM-service token.
exec > >(python3 -u -c '
import re
import sys
patterns = [
    (re.compile(r"/Users/[^/\s]+"), "/Users/<redacted>"),
    (re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)(access_token|refresh_token|id_token|token|code|code_verifier|authorization_code|otp)=([^&\s]+)"), r"\1=<redacted>"),
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "<redacted-email>"),
    (re.compile(r"http://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"), "http://127.0.0.1:<port>/<redacted>"),
    (re.compile(r"ws://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"), "ws://127.0.0.1:<port>/<redacted>"),
]
for line in sys.stdin:
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    sys.stdout.write(line)
    sys.stdout.flush()
' | tee "$EVIDENCE_DIR/run.log") 2>&1

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

need flutter
need python3

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
driver_hold_required=true
premature_exit_rejected=true
retained_log_max_bytes=524288
launch_cycles_requested=$LAUNCH_CYCLES
SCOPE

run_launch_cycle() {
  local cycle="$1"
  local label
  if [[ "$cycle" == "1" ]]; then
    label="first-launch"
  else
    label="cold-relaunch-$cycle"
  fi

  echo "== physical iPhone $label =="
  (
    cd "$ROOT"
    python3 "$ROOT/scripts/device-lab/flutter-run-driver.py" \
      --log "$EVIDENCE_DIR/$label-flutter-run.txt" \
      --timeout-seconds "$RUN_TIMEOUT_SECONDS" \
      --hold-seconds "$READY_HOLD_SECONDS" \
      --max-log-bytes 524288 \
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
driver_hold_required=true
premature_exit_rejected=true
retained_log_max_bytes=524288
launch_cycles_completed=$completed
RESULT

echo "PHYSICAL IOS LAUNCH/RELAUNCH SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
