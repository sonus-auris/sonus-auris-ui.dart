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
RUN_FLUTTER_MACOS="${SONUS_RUN_FLUTTER_MACOS:-1}"
mkdir -p "$RUN_DIR"
exec > >(tee "$RUN_DIR/orchestrator.log") 2>&1

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This orchestrator must run on the MacBook that owns Xcode and the attached devices." >&2
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
  if [[ "$status" == "0" ]]; then
    record_status "$name" passed
  elif [[ "$status" == "78" ]]; then
    echo "$name skipped because no eligible target was detected."
    record_status "$name" skipped
  else
    echo "$name failed with exit status $status" >&2
    record_status "$name" failed
  fi
  return 0
}

find_physical_android() {
  if ! command -v adb >/dev/null 2>&1; then
    return 1
  fi
  adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1; exit }'
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
    android_serial="$(find_physical_android || true)"
    if [[ -z "$android_serial" ]]; then
      echo "Physical Android was required but no authorized USB target was found." >&2
      record_status android-device failed
    else
      run_target android-device "$ROOT/scripts/device-lab/android-attached-smoke.sh" \
        "$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"
    fi
    ;;
  auto)
    android_serial="$(find_physical_android || true)"
    if [[ -n "$android_serial" ]]; then
      run_target android-device "$ROOT/scripts/device-lab/android-attached-smoke.sh" \
        "$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"
    else
      echo "No authorized physical Android target detected; skipping Android smoke."
      record_status android-device skipped
    fi
    ;;
  *) record_status android-device skipped ;;
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
physical_device_claims_require_this_run=true
SUMMARY
cat "$RUN_DIR/results.txt"
echo "Evidence root: $RUN_DIR"

if (( failures > 0 )); then
  exit 1
fi
exit 0
