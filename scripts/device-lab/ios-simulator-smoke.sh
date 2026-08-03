#!/usr/bin/env bash
# Build, install, launch, cold-relaunch, and inspect Sonus Auris on an iOS
# Simulator without erasing the simulator or clearing the app's data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUNDLE_ID="com.ores.audioDashcam"
UDID="${1:-${IOS_SIMULATOR_UDID:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-simulator-$STAMP}"
CAPTURE_SCREENSHOT="${SONUS_CAPTURE_SCREENSHOT:-0}"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee "$EVIDENCE_DIR/run.log") 2>&1

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

find "$APP" -type f -print 2>/dev/null \
  | LC_ALL=C sort \
  | while IFS= read -r app_file; do shasum -a 256 "$app_file"; done \
  > "$EVIDENCE_DIR/app-files.sha256" || true

sanitize_stream() {
  python3 -c '
import re
import sys
text = sys.stdin.read()
patterns = [
    (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", "<redacted-jwt>"),
    (r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization_code|otp)=([^&\s]+)", r"\1=<redacted>"),
    (r"http://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+", "http://127.0.0.1:<port>/<redacted>"),
]
for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text)
sys.stdout.write(text)
'
}

capture_logs() {
  xcrun simctl spawn "$UDID" log show \
    --last 3m \
    --style compact \
    --predicate 'process == "Runner" OR subsystem BEGINSWITH "app.sonusauris"' \
    2>/dev/null \
    | tail -n 500 \
    | sanitize_stream > "$EVIDENCE_DIR/simulator.log" || true
}

assert_no_fatal_logs() {
  if grep -Eq 'Terminating app due to uncaught exception|Fatal error|EXC_CRASH|SIGABRT|Lost connection to device' "$EVIDENCE_DIR/simulator.log"; then
    echo "Fatal iOS Simulator evidence was found; inspect $EVIDENCE_DIR/simulator.log" >&2
    return 1
  fi
}

launch_app() {
  label="$1"
  output="$(xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" 2>&1 || true)"
  printf '%s\n' "$output" | sanitize_stream | tee "$EVIDENCE_DIR/$label.txt"
  pid="$(printf '%s\n' "$output" | awk -F ': ' 'NF > 1 { print $NF }' | tail -n 1 | tr -cd '0-9')"
  if [[ -z "$pid" ]]; then
    echo "simctl did not report a process ID for $BUNDLE_ID" >&2
    return 1
  fi
  sleep 6
  if ! xcrun simctl spawn "$UDID" ps -axo pid=,command= 2>/dev/null | awk -v expected="$pid" '$1 == expected { found=1 } END { exit found ? 0 : 1 }'; then
    echo "Simulator process $pid did not remain alive after launch" >&2
    return 1
  fi
  printf 'pid=%s\n' "$pid" > "$EVIDENCE_DIR/$label-process.txt"
}

echo "== install without erasing simulator app data =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

launch_app first-launch
if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  xcrun simctl io "$UDID" screenshot "$EVIDENCE_DIR/first-launch.png" >/dev/null
fi
capture_logs
assert_no_fatal_logs

# A process termination/relaunch is intentionally exercised, but package data
# remains intact. This mirrors the safe physical-device lifecycle boundary.
echo "== cold relaunch =="
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
launch_app cold-relaunch
if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  xcrun simctl io "$UDID" screenshot "$EVIDENCE_DIR/cold-relaunch.png" >/dev/null
fi
capture_logs
assert_no_fatal_logs

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=ios-simulator-install-launch-cold-relaunch
bundle_id=$BUNDLE_ID
simulator_erased=false
app_data_cleared=false
screenshot_captured=$CAPTURE_SCREENSHOT
RESULT

echo "IOS SIMULATOR SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
