#!/usr/bin/env bash
# Bounded, non-destructive Flutter launch smoke for a paired physical iPhone.
# Requires the operator's normal Apple development signing configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEVICE_ID="${1:-${IOS_DEVICE_ID:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-device-$STAMP}"
READY_HOLD_SECONDS="${SONUS_IOS_READY_HOLD_SECONDS:-12}"
RUN_TIMEOUT_SECONDS="${SONUS_IOS_RUN_TIMEOUT_SECONDS:-240}"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee "$EVIDENCE_DIR/run.log") 2>&1

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

need flutter
need python3

flutter_devices_json="$(flutter devices --machine 2>/dev/null || true)"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(printf '%s' "$flutter_devices_json" | python3 -c '
import json
import sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
for device in devices:
    target = str(device.get("targetPlatform", "")).lower()
    platform = str(device.get("platform", "")).lower()
    if device.get("emulator"):
        continue
    if target.startswith("ios") or platform.startswith("ios"):
        print(device.get("id", ""))
        break
')"
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
print("target_fingerprint=" + hashlib.sha256(needle.encode()).hexdigest()[:12])
print("device_class=physical-iPhone")
print("platform=" + str(selected.get("platform", "ios")))
print("target_platform=" + str(selected.get("targetPlatform", "ios")))
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
SCOPE

# Keep the physical-device command bounded. Flutter prints VM-service URLs with
# per-run authentication material, so the Python driver redacts those and other
# token-shaped values before writing evidence.
(
  cd "$ROOT"
  python3 - "$EVIDENCE_DIR/flutter-run.txt" "$RUN_TIMEOUT_SECONDS" "$READY_HOLD_SECONDS" \
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
    (re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization_code|otp)=([^&\s]+)"), r"\1=<redacted>"),
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

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=physical-iphone-development-signed-install-and-bounded-launch
app_data_cleared=false
permissions_mutated=false
recording_automated=false
RESULT

echo "PHYSICAL IOS LAUNCH SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
