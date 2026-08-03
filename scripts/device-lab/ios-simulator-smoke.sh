#!/usr/bin/env bash
# Build, install, launch, cold-relaunch, update in place, and inspect Sonus
# Auris on an iOS Simulator without erasing the simulator or clearing app data.
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

need xcrun
need flutter
need python3
need shasum

mkdir -p "$EVIDENCE_DIR"
# Sanitize the complete run log, including build-tool failures that may contain
# the local account name, an auth callback, or token-shaped values.
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
]
for line in sys.stdin:
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    sys.stdout.write(line)
    sys.stdout.flush()
' | tee "$EVIDENCE_DIR/run.log") 2>&1

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
        item = (device.get("udid", ""), device.get("name", ""), runtime)
        if device.get("state") == "Booted":
            booted.append(item)
        else:
            available.append(item)
choices = booted or available
if choices:
    print(choices[0][0])
')"
fi

if [[ -z "$UDID" ]]; then
  echo "No available iPhone Simulator runtime was found. Install an iOS Simulator runtime in Xcode Settings > Platforms." >&2
  exit 3
fi

printf '%s' "$simulator_json" | SIM_UDID="$UDID" python3 -c '
import hashlib
import json
import os
import sys
payload = json.load(sys.stdin)
udid = os.environ["SIM_UDID"]
found = None
for runtime, devices in payload.get("devices", {}).items():
    for device in devices:
        if device.get("udid") == udid:
            found = (runtime, device)
            break
    if found:
        break
if not found:
    raise SystemExit("Requested simulator UDID is not available")
runtime, device = found
print("target_fingerprint=" + hashlib.sha256(udid.encode()).hexdigest()[:12])
print("name=" + device.get("name", "unknown"))
print("runtime=" + runtime.rsplit(".", 1)[-1].replace("-", "."))
print("initial_state=" + device.get("state", "unknown"))
' > "$EVIDENCE_DIR/device.txt"

# `boot` returns an error when already booted; bootstatus is the authoritative
# readiness gate and does not erase or reset simulator contents.
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
  APP=""
  for candidate in "$ROOT"/build/ios/*iphonesimulator*/Runner.app; do
    if [[ -d "$candidate" ]]; then
      APP="$candidate"
      break
    fi
  done
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Flutter did not produce an iOS Simulator Runner.app" >&2
  exit 4
fi

# Hash relative app-bundle paths only; never put the local username or checkout
# root into uploaded evidence.
APP_ROOT="$APP" python3 - <<'PY' > "$EVIDENCE_DIR/app-files.sha256"
import hashlib
import os
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
  python3 -c '
import re
import sys
text = sys.stdin.read()
patterns = [
    (r"/Users/[^/\s]+", "/Users/<redacted>"),
    (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", "<redacted-jwt>"),
    (r"(?i)(access_token|refresh_token|id_token|token|code|code_verifier|authorization_code|otp)=([^&\s]+)", r"\1=<redacted>"),
    (r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "<redacted-email>"),
    (r"http://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+", "http://127.0.0.1:<port>/<redacted>"),
]
for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text)
sys.stdout.write(text)
'
}

capture_logs() {
  local label="$1"
  local predicate='process == "Runner" OR subsystem BEGINSWITH "app.sonusauris"'
  if [[ "$CURRENT_PID" =~ ^[0-9]+$ ]]; then
    predicate="processIdentifier == $CURRENT_PID"
  fi
  xcrun simctl spawn "$UDID" log show \
    --last 3m \
    --style compact \
    --predicate "$predicate" \
    2>/dev/null \
    | tail -n 500 \
    | sanitize_stream > "$EVIDENCE_DIR/$label-simulator.log" || true
}

assert_no_fatal_logs() {
  local file="$1"
  if grep -Eq 'Terminating app due to uncaught exception|Fatal error|EXC_CRASH|SIGABRT|Lost connection to device|Library not loaded|dyld.*Reason' "$file"; then
    echo "Fatal iOS Simulator evidence was found; inspect $file" >&2
    return 1
  fi
}

launch_app() {
  local label="$1"
  local output
  local pid
  output="$(xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" 2>&1 || true)"
  printf '%s\n' "$output" | sanitize_stream | tee "$EVIDENCE_DIR/$label.txt"
  pid="$(printf '%s\n' "$output" | awk -F ': ' -v bundle="$BUNDLE_ID" '$1 == bundle && $2 ~ /^[0-9]+$/ { print $2 }' | tail -n 1)"
  if [[ -z "$pid" ]]; then
    CURRENT_PID=""
    capture_logs "$label-launch-failure"
    echo "simctl did not report a process ID for $BUNDLE_ID" >&2
    return 1
  fi
  CURRENT_PID="$pid"
  sleep 6
  # `simctl launch` returns the host PID of the Simulator app process. Signal 0
  # checks liveness without sending a signal; invoking `ps` inside the simulated
  # runtime is not portable across installed iOS runtime images.
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    capture_logs "$label-launch-failure"
    echo "Simulator process $pid did not remain alive after launch" >&2
    return 1
  fi
  ps -p "$pid" -o pid=,command= 2>/dev/null \
    | sanitize_stream > "$EVIDENCE_DIR/$label-process.txt" || true
  printf 'pid=%s\n' "$pid" >> "$EVIDENCE_DIR/$label-process.txt"
}

data_container_fingerprint() {
  local container
  container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  if [[ -z "$container" ]]; then
    return 1
  fi
  printf '%s' "$container" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}

echo "== install without erasing simulator app data =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

launch_app first-launch
if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  xcrun simctl io "$UDID" screenshot "$EVIDENCE_DIR/first-launch.png" >/dev/null
fi
capture_logs first-launch
assert_no_fatal_logs "$EVIDENCE_DIR/first-launch-simulator.log"

# A process termination/relaunch is intentionally exercised, but package data
# remains intact. This mirrors the safe physical-device lifecycle boundary.
echo "== cold relaunch =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
launch_app cold-relaunch
if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  xcrun simctl io "$UDID" screenshot "$EVIDENCE_DIR/cold-relaunch.png" >/dev/null
fi
capture_logs cold-relaunch
assert_no_fatal_logs "$EVIDENCE_DIR/cold-relaunch-simulator.log"

# Reinstall the same candidate in place and prove CoreSimulator kept the same
# app data container. This catches accidental uninstall/erase behavior while
# avoiding reads of app-private user data.
echo "== in-place update + post-update relaunch =="
before_fingerprint="$(data_container_fingerprint)" || {
  echo "Could not fingerprint the installed simulator data container." >&2
  exit 5
}
xcrun simctl install "$UDID" "$APP"
after_fingerprint="$(data_container_fingerprint)" || {
  echo "Could not fingerprint the simulator data container after update." >&2
  exit 5
}
if [[ "$before_fingerprint" != "$after_fingerprint" ]]; then
  echo "In-place simulator update replaced the app data container." >&2
  exit 5
fi
launch_app post-update-relaunch
if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  xcrun simctl io "$UDID" screenshot "$EVIDENCE_DIR/post-update-relaunch.png" >/dev/null
fi
capture_logs post-update-relaunch
assert_no_fatal_logs "$EVIDENCE_DIR/post-update-relaunch-simulator.log"
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
cat > "$EVIDENCE_DIR/data-container-preservation.txt" <<PRESERVATION
status=passed
before_fingerprint=$before_fingerprint
after_fingerprint=$after_fingerprint
in_place_reinstall=true
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
process_scoped_logs=true
screenshot_captured=$CAPTURE_SCREENSHOT
RESULT

echo "IOS SIMULATOR SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
