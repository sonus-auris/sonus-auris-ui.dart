#!/usr/bin/env bash
# Fail-closed Android microphone-permission denial probe. The candidate uses a
# package distinct from production and from the real-recording device lab, so a
# user-fixed denial cannot contaminate either app's permission or storage state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PRODUCTION_PKG="com.ores.sonus_auris"
RECORDING_LAB_PKG="$PRODUCTION_PKG.device_lab"
PERMISSION_LAB_PKG="$PRODUCTION_PKG.permission_lab"
TARGET="integration_test/device_lab_permission_denied_test.dart"
APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
SERIAL="${1:-${ANDROID_SERIAL:-}}"
ALLOW_EMULATOR="${SONUS_ALLOW_ANDROID_EMULATOR:-0}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/android-permission-$STAMP}"
EVIDENCE_POLICY="$ROOT/scripts/device-lab/evidence-policy.py"
DRIVE_PID=""
mkdir -p "$EVIDENCE_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

adb_() {
  adb -s "$SERIAL" "$@"
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

apk_application_id() {
  local candidate
  for candidate in \
    "$(command -v apkanalyzer 2>/dev/null || true)" \
    "${ANDROID_HOME:-}/cmdline-tools/latest/bin/apkanalyzer" \
    "${ANDROID_SDK_ROOT:-}/cmdline-tools/latest/bin/apkanalyzer"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      "$candidate" manifest application-id "$APK" | tr -d '\r' | head -n 1
      return 0
    fi
  done

  for candidate in \
    "$(command -v aapt 2>/dev/null || true)" \
    "$(find "${ANDROID_HOME:-/nonexistent}/build-tools" -type f -name aapt 2>/dev/null | sort -V | tail -n 1)" \
    "$(find "${ANDROID_SDK_ROOT:-/nonexistent}/build-tools" -type f -name aapt 2>/dev/null | sort -V | tail -n 1)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      "$candidate" dump badging "$APK" |
        sed -n "s/^package: name='\([^']*\)'.*/\1/p" |
        head -n 1
      return 0
    fi
  done

  echo "No apkanalyzer or aapt executable is available to verify the APK identity." >&2
  return 1
}

select_target() {
  if [[ -n "$SERIAL" ]]; then
    return 0
  fi
  local devices
  local count
  devices="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
  count="$(printf '%s\n' "$devices" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "$count" == "0" ]]; then
    echo "No authorized Android target is visible." >&2
    return 3
  fi
  if [[ "$count" != "1" ]]; then
    echo "Multiple Android targets are visible; set ANDROID_SERIAL explicitly." >&2
    return 3
  fi
  SERIAL="$devices"
}

cleanup() {
  local status=$?
  if [[ -n "$DRIVE_PID" ]]; then
    kill "$DRIVE_PID" 2>/dev/null || true
    wait "$DRIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERIAL" ]]; then
    adb_ shell am force-stop "$PERMISSION_LAB_PKG" >/dev/null 2>&1 || true
  fi
  return "$status"
}

main() {
  # The outer evidence pipeline temporarily disables errexit only to preserve
  # each component's status. Restore strict execution inside the probe.
  set -euo pipefail

  need adb
  need flutter
  need python3
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "A SHA-256 command (shasum or sha256sum) is required." >&2
    exit 2
  fi
  [[ -f "$EVIDENCE_POLICY" ]] || {
    echo "Evidence policy is missing: $EVIDENCE_POLICY" >&2
    exit 2
  }

  select_target
  local state
  state="$(adb devices | awk -v serial="$SERIAL" '$1 == serial { print $2; exit }')"
  if [[ "$state" != "device" ]]; then
    echo "Android target is unavailable, unauthorized, or offline." >&2
    exit 3
  fi
  local qemu
  qemu="$(adb_ shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')"
  if [[ "$qemu" == "1" && "$ALLOW_EMULATOR" != "1" ]]; then
    echo "This operator probe requires a physical Android by default." >&2
    exit 3
  fi

  local serial_fingerprint
  serial_fingerprint="$(printf '%s' "$SERIAL" | {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
  } | awk '{print substr($1, 1, 12)}')"
  {
    echo "target_fingerprint=$serial_fingerprint"
    echo "transport=authorized-adb"
    echo "emulator=$([[ "$qemu" == "1" ]] && echo true || echo false)"
    echo "sdk=$(adb_ shell getprop ro.build.version.sdk | tr -d '\r')"
    echo "security_patch=$(adb_ shell getprop ro.build.version.security_patch | tr -d '\r')"
  } > "$EVIDENCE_DIR/device.txt"

  echo "== build isolated permission-denial candidate =="
  (
    cd "$ROOT"
    flutter pub get
    SONUS_PERMISSION_LAB_ANDROID=1 flutter build apk --debug \
      --target="$TARGET" \
      --dart-define=SONUS_DEVICE_LAB_PERMISSION_DENIAL=true
  )
  [[ -s "$APK" ]] || {
    echo "Permission-lab APK build did not produce $APK" >&2
    exit 4
  }

  local observed_package
  observed_package="$(apk_application_id)"
  if [[ "$observed_package" != "$PERMISSION_LAB_PKG" ]]; then
    echo "Refusing APK with unexpected application ID '$observed_package'." >&2
    exit 4
  fi
  if [[ "$observed_package" == "$PRODUCTION_PKG" || "$observed_package" == "$RECORDING_LAB_PKG" ]]; then
    echo "Refusing to mutate permission state outside the dedicated permission lab." >&2
    exit 4
  fi
  printf '%s  %s\n' "$(hash_file "$APK")" "$(basename "$APK")" \
    > "$EVIDENCE_DIR/apk.sha256"
  cat > "$EVIDENCE_DIR/isolation.txt" <<ISOLATION
production_package=$PRODUCTION_PKG
recording_lab_package=$RECORDING_LAB_PKG
permission_lab_package=$PERMISSION_LAB_PKG
observed_apk_package=$observed_package
production_package_addressed=false
recording_lab_package_addressed=false
isolated_deep_link_scheme=sonusauris-permission-lab
ISOLATION

  echo "== install and force a user-fixed microphone denial =="
  adb_ install -r "$APK"
  adb_ shell am force-stop "$PERMISSION_LAB_PKG" >/dev/null 2>&1 || true
  adb_ shell pm revoke "$PERMISSION_LAB_PKG" android.permission.RECORD_AUDIO \
    >/dev/null 2>&1 || true
  adb_ shell pm clear-permission-flags \
    "$PERMISSION_LAB_PKG" android.permission.RECORD_AUDIO user-set user-fixed
  adb_ shell pm set-permission-flags \
    "$PERMISSION_LAB_PKG" android.permission.RECORD_AUDIO user-set user-fixed
  adb_ shell dumpsys package "$PERMISSION_LAB_PKG" \
    > "$EVIDENCE_DIR/permission-state.txt"

  if ! grep -F 'android.permission.RECORD_AUDIO: granted=false' \
    "$EVIDENCE_DIR/permission-state.txt" >/dev/null; then
    echo "Permission lab did not enter the denied RECORD_AUDIO state." >&2
    exit 5
  fi
  if ! grep -E 'android.permission.RECORD_AUDIO: granted=false.*USER_(SET|FIXED)' \
    "$EVIDENCE_DIR/permission-state.txt" >/dev/null; then
    echo "Permission lab denial was not marked as a user decision." >&2
    exit 5
  fi

  trap cleanup EXIT HUP INT TERM
  echo "== drive denied-permission integration target =="
  local drive_log="$EVIDENCE_DIR/drive.log"
  (
    set -o pipefail
    (
      cd "$ROOT"
      SONUS_PERMISSION_LAB_ANDROID=1 flutter drive \
        --driver=test_driver/integration_test.dart \
        --target="$TARGET" \
        --use-application-binary="$APK" \
        --dart-define=SONUS_DEVICE_LAB_PERMISSION_DENIAL=true \
        -d "$SERIAL"
    ) 2>&1 | python3 "$EVIDENCE_POLICY" --stream | tee "$drive_log"
  ) &
  DRIVE_PID=$!

  local deadline=$((SECONDS + 480))
  while kill -0 "$DRIVE_PID" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "Permission-denial flutter drive exceeded the 8-minute host deadline." >&2
      kill "$DRIVE_PID" 2>/dev/null || true
      wait "$DRIVE_PID" 2>/dev/null || true
      DRIVE_PID=""
      exit 6
    fi
    sleep 1
  done
  local drive_status=0
  wait "$DRIVE_PID" || drive_status=$?
  DRIVE_PID=""
  if [[ "$drive_status" != "0" ]]; then
    echo "Permission-denial Flutter drive/evidence pipeline failed with status $drive_status." >&2
    exit "$drive_status"
  fi

  grep -Fq 'SONUS_PERMISSION_DENIAL_RESULT' "$drive_log"
  grep -Fq 'SONUS_PERMISSION_DENIAL_CLEANUP_PASSED' "$drive_log"

  adb_ shell dumpsys activity services "$PERMISSION_LAB_PKG" \
    > "$EVIDENCE_DIR/services.txt" 2>&1 || true
  adb_ shell appops get "$PERMISSION_LAB_PKG" RECORD_AUDIO \
    > "$EVIDENCE_DIR/appops-record-audio.txt" 2>&1 || true
  if grep -Fq 'com.pravera.flutter_foreground_task.service.ForegroundService' \
    "$EVIDENCE_DIR/services.txt"; then
    echo "Denied permission unexpectedly left a microphone foreground service." >&2
    exit 7
  fi
  if grep -Eq 'RECORD_AUDIO: (allow|foreground)' "$EVIDENCE_DIR/appops-record-audio.txt"; then
    echo "Denied permission unexpectedly produced an allowed microphone app-op." >&2
    exit 7
  fi

  cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=isolated-user-fixed-record-audio-denial
package=$PERMISSION_LAB_PKG
production_package_addressed=false
recording_lab_package_addressed=false
permission_error_surfaced=true
foreground_service_started=false
record_audio_appop_allowed=false
raw_audio_exported=false
probe_audio_artifacts=0
shared_logcat_cleared=false
permission_lab_package_uninstalled=false
RESULT
  echo "ANDROID ISOLATED PERMISSION-DENIAL PROBE PASSED"
  echo "Evidence: $EVIDENCE_DIR"
}

set +e
main 2>&1 | python3 "$EVIDENCE_POLICY" --stream | tee "$EVIDENCE_DIR/run.log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
main_status="${pipeline_status[0]}"
stream_status="${pipeline_status[1]}"
tee_status="${pipeline_status[2]}"

policy_status=0
python3 "$EVIDENCE_POLICY" --redact "$EVIDENCE_DIR" || policy_status=$?
if [[ "$main_status" != "0" ]]; then
  exit "$main_status"
fi
if [[ "$stream_status" != "0" ]]; then
  echo "Evidence stream sanitization failed with status $stream_status." >&2
  exit "$stream_status"
fi
if [[ "$tee_status" != "0" ]]; then
  echo "Evidence log capture failed with status $tee_status." >&2
  exit "$tee_status"
fi
if [[ "$policy_status" != "0" ]]; then
  exit "$policy_status"
fi
exit 0
