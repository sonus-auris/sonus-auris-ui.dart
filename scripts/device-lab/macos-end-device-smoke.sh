#!/usr/bin/env bash
# One-command Sonus Auris device lab for a Mac that can see an iOS Simulator,
# a paired iPhone, and/or an authorized USB Android handset.
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/run-$STAMP}"
RUN_IOS_SIMULATOR="${SONUS_RUN_IOS_SIMULATOR:-1}"
RUN_IOS_DEVICE="${SONUS_RUN_IOS_DEVICE:-auto}"
RUN_ANDROID_DEVICE="${SONUS_RUN_ANDROID_DEVICE:-auto}"
RUN_ANDROID_PERMISSION_DENIAL_PROBE="${SONUS_RUN_ANDROID_PERMISSION_DENIAL_PROBE:-0}"
RUN_ANDROID_RECORDING_PROBE="${SONUS_RUN_ANDROID_RECORDING_PROBE:-0}"
RUN_FLUTTER_MACOS="${SONUS_RUN_FLUTTER_MACOS:-1}"
EVIDENCE_POLICY="$ROOT/scripts/device-lab/evidence-policy.py"
mkdir -p "$RUN_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for device-lab evidence redaction." >&2
  exit 2
fi

# The orchestrator includes local evidence paths in its progress output. Redact
# the complete log while each child also sanitizes its own run log.
exec > >(python3 -u -c '
import re
import sys
patterns = [
    (re.compile(r"/Users/[^/\s]+"), "/Users/<redacted>"),
    (re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)(access_token|refresh_token|id_token|token|code|code_verifier|authorization_code|otp)=([^&\s]+)"), r"\1=<redacted>"),
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "<redacted-email>"),
]
for line in sys.stdin:
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    sys.stdout.write(line)
    sys.stdout.flush()
' | tee "$RUN_DIR/orchestrator.log") 2>&1

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This orchestrator must run on the MacBook that owns Xcode and the attached devices." >&2
  exit 2
fi
if [[ ! -f "$EVIDENCE_POLICY" ]]; then
  echo "Device-lab evidence policy is missing: $EVIDENCE_POLICY" >&2
  exit 2
fi

failures=0
passes=0
skips=0

record_status() {
  name="$1"
  status="$2"
  printf '%s=%s\n' "$name" "$status" >> "$RUN_DIR/results.txt"
  case "$status" in
    passed) passes=$((passes + 1)) ;;
    skipped) skips=$((skips + 1)) ;;
    *) failures=$((failures + 1)) ;;
  esac
}

run_target() {
  name="$1"
  shift
  evidence="$RUN_DIR/$name"
  mkdir -p "$evidence"
  echo
  echo "===== $name ====="
  SONUS_DEVICE_LAB_DIR="$evidence" bash "$@"
  status=$?

  policy_status=0
  echo "== redact and verify $name evidence =="
  python3 "$EVIDENCE_POLICY" --redact "$evidence" || policy_status=$?

  if [[ "$status" == "0" && "$policy_status" == "0" ]]; then
    record_status "$name" passed
  elif [[ "$status" == "78" && "$policy_status" == "0" ]]; then
    echo "$name skipped because no eligible target was detected."
    record_status "$name" skipped
  else
    if [[ "$status" != "0" && "$status" != "78" ]]; then
      echo "$name failed with exit status $status" >&2
    fi
    if [[ "$policy_status" != "0" ]]; then
      echo "$name evidence failed privacy policy with exit status $policy_status" >&2
    fi
    record_status "$name" failed
  fi
  return 0
}

physical_android_targets() {
  if ! command -v adb >/dev/null 2>&1; then
    return 1
  fi
  adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1 }'
}

select_physical_android() {
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    printf '%s\n' "$ANDROID_SERIAL"
    return 0
  fi
  local targets
  local count
  targets="$(physical_android_targets || true)"
  count="$(printf '%s\n' "$targets" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    printf '%s\n' "$targets"
    return 0
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "Multiple authorized physical Android targets are attached. Set ANDROID_SERIAL explicitly." >&2
    return 2
  fi
  return 1
}

physical_ios_visible() {
  if ! command -v flutter >/dev/null 2>&1; then
    return 1
  fi
  flutter devices --machine 2>/dev/null | python3 -c '
import json
import sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
for device in devices:
    target = str(device.get("targetPlatform", "")).lower()
    platform = str(device.get("platform", "")).lower()
    if not device.get("emulator") and (target.startswith("ios") or platform.startswith("ios")):
        raise SystemExit(0)
raise SystemExit(1)
' >/dev/null 2>&1
}

: > "$RUN_DIR/results.txt"

if [[ "$RUN_IOS_SIMULATOR" == "1" ]]; then
  run_target ios-simulator "$ROOT/scripts/device-lab/ios-simulator-smoke.sh"
else
  record_status ios-simulator skipped
fi

case "$RUN_IOS_DEVICE" in
  1|true|yes)
    run_target ios-device "$ROOT/scripts/device-lab/ios-attached-smoke.sh"
    ;;
  auto)
    if physical_ios_visible; then
      run_target ios-device "$ROOT/scripts/device-lab/ios-attached-smoke.sh"
    else
      echo "No paired physical iPhone detected; skipping physical iOS smoke."
      record_status ios-device skipped
    fi
    ;;
  *) record_status ios-device skipped ;;
esac

case "$RUN_ANDROID_DEVICE" in
  1|true|yes)
    android_serial="$(select_physical_android)"
    selection_status=$?
    if [[ "$selection_status" != "0" || -z "$android_serial" ]]; then
      echo "Physical Android was required but one unambiguous authorized USB target was not found." >&2
      record_status android-device failed
    else
      run_target android-device "$ROOT/scripts/device-lab/android-attached-smoke.sh" \
        "$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"
    fi
    ;;
  auto)
    android_serial="$(select_physical_android)"
    selection_status=$?
    if [[ "$selection_status" == "0" && -n "$android_serial" ]]; then
      run_target android-device "$ROOT/scripts/device-lab/android-attached-smoke.sh" \
        "$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"
    elif [[ "$selection_status" == "2" ]]; then
      record_status android-device failed
    else
      echo "No authorized physical Android target detected; skipping Android smoke."
      record_status android-device skipped
    fi
    ;;
  *) record_status android-device skipped ;;
esac

# Permission denial is isolated from both production and the recording lab. It
# opens no microphone and requires no recording consent, but remains opt-in
# because it deliberately exercises a user-fixed runtime permission state.
case "$RUN_ANDROID_PERMISSION_DENIAL_PROBE" in
  1|true|yes)
    android_permission_serial="$(select_physical_android)"
    selection_status=$?
    if [[ "$selection_status" != "0" || -z "$android_permission_serial" ]]; then
      echo "Android permission-denial probe was requested but no unambiguous authorized physical target was found." >&2
      record_status android-permission-denial-probe failed
    else
      run_target android-permission-denial-probe \
        "$ROOT/scripts/device-lab/android-permission-denial-probe.sh" \
        "$android_permission_serial"
    fi
    ;;
  *) record_status android-permission-denial-probe skipped ;;
esac

# Real microphone automation is intentionally separate from the default Android
# lifecycle smoke. It requires both an explicit opt-in target flag and the exact
# consent phrase enforced by android-recording-probe.sh.
case "$RUN_ANDROID_RECORDING_PROBE" in
  1|true|yes)
    android_recording_serial="$(select_physical_android)"
    selection_status=$?
    if [[ "$selection_status" != "0" || -z "$android_recording_serial" ]]; then
      echo "Android recording probe was requested but no unambiguous authorized physical target was found." >&2
      record_status android-recording-probe failed
    else
      run_target android-recording-probe \
        "$ROOT/scripts/device-lab/android-recording-probe.sh" \
        "$android_recording_serial"
    fi
    ;;
  *) record_status android-recording-probe skipped ;;
esac

if [[ "$RUN_FLUTTER_MACOS" == "1" ]]; then
  run_target flutter-macos "$ROOT/scripts/device-lab/flutter-macos-smoke.sh"
else
  record_status flutter-macos skipped
fi

cat > "$RUN_DIR/summary.txt" <<SUMMARY
passes=$passes
skips=$skips
failures=$failures
evidence_policy=required
physical_device_claims_require_this_run=true
android_permission_denial_probe_opt_in=$RUN_ANDROID_PERMISSION_DENIAL_PROBE
android_recording_probe_opt_in=$RUN_ANDROID_RECORDING_PROBE
SUMMARY
cat "$RUN_DIR/results.txt"
echo "Evidence root: $RUN_DIR"

if (( failures > 0 )); then
  exit 1
fi
exit 0
