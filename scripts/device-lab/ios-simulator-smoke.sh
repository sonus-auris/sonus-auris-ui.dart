#!/usr/bin/env bash
# Non-destructive install, lifecycle, update, and evidence smoke for iOS Simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUNDLE_ID="com.ores.audioDashcam"
UDID="${1:-${IOS_SIMULATOR_UDID:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-simulator-$STAMP}"
CAPTURE_SCREENSHOT="${SONUS_CAPTURE_SCREENSHOT:-0}"
CURRENT_PID=""

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}
for command in xcrun flutter python3 shasum; do need "$command"; done

mkdir -p "$EVIDENCE_DIR"
exec > >(python3 "$ROOT/scripts/device-lab/evidence-policy.py" --stream \
  | tee "$EVIDENCE_DIR/run.log") 2>&1

simulator_json="$(xcrun simctl list devices available --json)"
if [[ -z "$UDID" ]]; then
  UDID="$(python3 -c '
import json, sys
payload = json.load(sys.stdin)
booted, available = [], []
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True) or "iPhone" not in device.get("name", ""):
            continue
        (booted if device.get("state") == "Booted" else available).append(device["udid"])
choices = booted or available
if choices:
    print(choices[0])
' <<<"$simulator_json")"
fi
[[ -n "$UDID" ]] || {
  echo "No available iPhone Simulator runtime was found. Install one in Xcode Settings > Platforms." >&2
  exit 3
}

SIM_UDID="$UDID" python3 -c '
import hashlib, json, os, sys
payload, udid = json.load(sys.stdin), os.environ["SIM_UDID"]
for runtime, devices in payload.get("devices", {}).items():
    for device in devices:
        if device.get("udid") != udid:
            continue
        print("target_fingerprint=" + hashlib.sha256(udid.encode()).hexdigest()[:12])
        print("name=" + device.get("name", "unknown"))
        print("runtime=" + runtime.rsplit(".", 1)[-1].replace("-", "."))
        print("initial_state=" + device.get("state", "unknown"))
        raise SystemExit(0)
raise SystemExit("Requested simulator UDID is not available")
' <<<"$simulator_json" > "$EVIDENCE_DIR/device.txt"

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
(
  cd "$ROOT"
  flutter pub get
  flutter build ios --simulator --debug \
    --dart-define=SONUS_BACKEND_BASE_URL=https://ci.invalid \
    --dart-define=SONUS_SUPABASE_URL=https://ci.supabase.co \
    --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_simulator_smoke
)

APP="$ROOT/build/ios/iphonesimulator/Runner.app"
if [[ ! -d "$APP" ]]; then
  APP="$(find "$ROOT/build/ios" -maxdepth 3 -type d -path '*iphonesimulator*/Runner.app' -print -quit 2>/dev/null || true)"
fi
[[ -n "$APP" && -d "$APP" ]] || {
  echo "Flutter did not produce an iOS Simulator Runner.app" >&2
  exit 4
}

APP_ROOT="$APP" python3 - <<'PY' > "$EVIDENCE_DIR/app-files.sha256"
import hashlib, os
from pathlib import Path
root = Path(os.environ["APP_ROOT"])
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    print(f"{digest.hexdigest()}  {path.relative_to(root)}")
PY

sanitize_stream() {
  python3 "$ROOT/scripts/device-lab/evidence-policy.py" --stream
}

capture_logs() {
  local label="${1:?log label is required}"
  local predicate='process == "Runner" OR subsystem BEGINSWITH "app.sonusauris"'
  if [[ "$CURRENT_PID" =~ ^[0-9]+$ ]]; then
    predicate="processIdentifier == $CURRENT_PID"
  fi
  xcrun simctl spawn "$UDID" log show --last 3m --style compact \
    --predicate "$predicate" 2>/dev/null \
    | sanitize_stream \
    | python3 "$ROOT/scripts/device-lab/bounded-log.py" --max-bytes 524288 \
    > "$EVIDENCE_DIR/$label-simulator.log" || true
}

assert_no_fatal_logs() {
  local file="${1:?log file is required}"
  if grep -Eq 'Terminating app due to uncaught exception|Fatal error|EXC_CRASH|SIGABRT|Lost connection to device|Library not loaded|dyld.*Reason' "$file"; then
    echo "Fatal iOS Simulator evidence was found; inspect $file" >&2
    return 1
  fi
}

launch_app() {
  local label="${1:?launch label is required}" output pid
  output="$(xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" 2>&1 || true)"
  printf '%s\n' "$output" | sanitize_stream | tee "$EVIDENCE_DIR/$label.txt"
  pid="$(awk -F ': ' -v bundle="$BUNDLE_ID" '$1 == bundle && $2 ~ /^[0-9]+$/ { print $2 }' <<<"$output" | tail -n 1)"
  if [[ -z "$pid" ]]; then
    CURRENT_PID=""
    capture_logs "$label-launch-failure"
    echo "simctl did not report a process ID for $BUNDLE_ID" >&2
    return 1
  fi
  CURRENT_PID="$pid"
  sleep 6
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    capture_logs "$label-launch-failure"
    echo "Simulator process $pid did not remain alive after launch" >&2
    return 1
  fi
  ps -p "$pid" -o pid=,command= 2>/dev/null \
    | sanitize_stream > "$EVIDENCE_DIR/$label-process.txt" || true
  printf 'pid=%s\n' "$pid" >> "$EVIDENCE_DIR/$label-process.txt"
}

capture_phase() {
  local label="${1:?phase label is required}"
  launch_app "$label"
  if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
    xcrun simctl io "$UDID" screenshot "$EVIDENCE_DIR/$label.png" >/dev/null
  fi
  capture_logs "$label"
  assert_no_fatal_logs "$EVIDENCE_DIR/$label-simulator.log"
}

data_container_path() {
  xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null
}
container_fingerprint() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}

write_update_sentinel() {
  DATA_CONTAINER="${1:?container is required}" SENTINEL_NAME="${2:?sentinel is required}" python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["DATA_CONTAINER"]).resolve()
marker = root / "Library" / "Application Support" / "SonusAurisDeviceLab" / os.environ["SENTINEL_NAME"]
marker.parent.mkdir(parents=True, exist_ok=True)
marker.write_text("sonus-auris-device-lab-update-sentinel-v1\n", encoding="utf-8")
PY
}

verify_and_remove_update_sentinel() {
  DATA_CONTAINER="${1:?container is required}" SENTINEL_NAME="${2:?sentinel is required}" python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["DATA_CONTAINER"]).resolve()
marker = root / "Library" / "Application Support" / "SonusAurisDeviceLab" / os.environ["SENTINEL_NAME"]
expected = "sonus-auris-device-lab-update-sentinel-v1\n"
if not marker.is_file() or marker.read_text(encoding="utf-8") != expected:
    raise SystemExit("test-owned update sentinel was not preserved")
marker.unlink()
try:
    marker.parent.rmdir()
except OSError:
    pass
PY
}

echo "== install without erasing simulator app data =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
capture_phase first-launch

echo "== cold relaunch =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
capture_phase cold-relaunch

echo "== in-place update + post-update relaunch =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
before_container="$(data_container_path)" || {
  echo "Could not locate the installed simulator data container." >&2
  exit 5
}
before_fingerprint="$(container_fingerprint "$before_container")"
sentinel_name="update-sentinel-$(printf '%s' "$STAMP-$before_fingerprint" | shasum -a 256 | awk '{print substr($1, 1, 16)}').txt"
write_update_sentinel "$before_container" "$sentinel_name"
xcrun simctl install "$UDID" "$APP"
after_container="$(data_container_path)" || {
  echo "Could not locate the simulator data container after update." >&2
  exit 5
}
after_fingerprint="$(container_fingerprint "$after_container")"
container_relocated=$([[ "$before_fingerprint" == "$after_fingerprint" ]] && echo false || echo true)
verify_and_remove_update_sentinel "$after_container" "$sentinel_name" || {
  echo "In-place simulator update did not preserve the test-owned app-data sentinel." >&2
  exit 5
}
capture_phase post-update-relaunch
xcrun simctl terminate "$UDID" "$BUNDLE_ID"

cat > "$EVIDENCE_DIR/data-container-preservation.txt" <<PRESERVATION
status=passed
before_fingerprint=$before_fingerprint
after_fingerprint=$after_fingerprint
container_relocated=$container_relocated
in_place_reinstall=true
test_owned_sentinel_preserved=true
test_owned_sentinel_removed=true
existing_app_files_enumerated=false
app_data_cleared=false
post_update_relaunch=true
PRESERVATION

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=ios-simulator-install-launch-cold-relaunch-in-place-update
bundle_id=$BUNDLE_ID
simulator_erased=false
app_data_cleared=false
in_place_update_completed=true
data_container_preserved=true
preservation_proof=test-owned-sentinel
process_scoped_logs=true
streaming_redaction=true
startup_log_context_preserved=true
simulator_log_max_bytes=524288
screenshot_captured=$CAPTURE_SCREENSHOT
RESULT

echo "IOS SIMULATOR SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
