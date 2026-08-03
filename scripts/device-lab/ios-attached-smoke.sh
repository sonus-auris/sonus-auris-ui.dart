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

printf '%s' "$flutter_devices_json" | IOS_DEVICE_ID="$DEVICE_ID" python3 -c '
import hashlib
import json
import os
import sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
needle = os.environ["IOS_DEVICE_ID"]
selected = next((d for d in devices if d.get("id") == needle), {})
connection = selected.get("connectionInterface", selected.get("connection-interface", "unknown"))
print("target_fingerprint=" + hashlib.sha256(needle.encode()).hexdigest()[:12])
print("device_class=physical-iPhone")
print("platform=" + str(selected.get("platform", "ios")))
print("target_platform=" + str(selected.get("targetPlatform", "ios")))
print("connection_interface=" + str(connection))
print("emulator=false")
' > "$EVIDENCE_DIR/device.txt"

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
    python3 - "$EVIDENCE_DIR/$label-flutter-run.txt" "$RUN_TIMEOUT_SECONDS" "$READY_HOLD_SECONDS" \
      flutter run \
      -d "$DEVICE_ID" \
      --debug \
      --device-timeout 60 \
      -t lib/main.dart \
      --dart-define=SONUS_BACKEND_BASE_URL=https://ci.invalid \
      --dart-define=SONUS_SUPABASE_URL=https://ci.supabase.co \
      --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_physical_device_lab <<'PY'
import os
import re
import selectors
import subprocess
import sys
import time

log_path = sys.argv[1]
timeout_seconds = int(sys.argv[2])
hold_seconds = int(sys.argv[3])
command = sys.argv[4:]

patterns = [
    (re.compile(r"/Users/[^/\s]+"), "/Users/<redacted>"),
    (re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization_code|otp)=([^&\s]+)"), r"\1=<redacted>"),
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "<redacted-email>"),
    (re.compile(r"http://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"), "http://127.0.0.1:<port>/<redacted>"),
    (re.compile(r"ws://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"), "ws://127.0.0.1:<port>/<redacted>"),
    (re.compile(r"(?i)(on|for) [^\n]+ iPhone"), r"\1 <physical-iPhone>"),
]


def sanitize(line: str) -> str:
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    return line


process = subprocess.Popen(
    command,
    cwd=os.getcwd(),
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)
assert process.stdout is not None
assert process.stdin is not None
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
started = time.monotonic()
ready_at = None
ready_markers = (
    "Flutter run key commands",
    "A Dart VM Service on",
    "The Flutter DevTools debugger and profiler",
)
failure_markers = (
    "Could not build the precompiled application for the device",
    "Failed to build iOS app",
    "No valid code signing certificates were found",
    "Error launching application on",
    "Lost connection to device",
)
failed = False

with open(log_path, "w", encoding="utf-8") as log:
    while True:
        if process.poll() is not None:
            break
        now = time.monotonic()
        if now - started > timeout_seconds:
            log.write("device_lab_timeout=true\n")
            failed = True
            process.terminate()
            break
        if ready_at is not None and now - ready_at >= hold_seconds:
            process.stdin.write("q\n")
            process.stdin.flush()
            break
        events = selector.select(timeout=0.5)
        for key, _ in events:
            line = key.fileobj.readline()
            if not line:
                continue
            if any(marker in line for marker in ready_markers) and ready_at is None:
                ready_at = time.monotonic()
            if any(marker in line for marker in failure_markers):
                failed = True
            clean = sanitize(line)
            sys.stdout.write(clean)
            sys.stdout.flush()
            log.write(clean)
            log.flush()

try:
    return_code = process.wait(timeout=30)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        return_code = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        return_code = process.wait(timeout=10)

if ready_at is None:
    failed = True
if return_code not in (0, -15):
    failed = True
if failed:
    raise SystemExit(1)
PY
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
launch_cycles_completed=$completed
RESULT

echo "PHYSICAL IOS LAUNCH/RELAUNCH SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
