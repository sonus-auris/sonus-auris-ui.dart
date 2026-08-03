#!/usr/bin/env bash
# Explicitly consented real-microphone/background probe for an attached Android
# handset. The candidate uses com.ores.sonus_auris.device_lab, never the Play
# Store package, and the Dart test removes all probe WAV/partial files before it
# returns. Shared device logcat is read from a timestamp and is never cleared.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PRODUCTION_PKG="com.ores.sonus_auris"
LAB_PKG="com.ores.sonus_auris.device_lab"
LAB_ACTIVITY="$LAB_PKG/com.ores.sonus_auris.MainActivity"
TARGET="integration_test/device_lab_recording_probe_test.dart"
APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
SERIAL="${1:-${ANDROID_SERIAL:-}}"
ALLOW_EMULATOR="${SONUS_ALLOW_ANDROID_EMULATOR:-0}"
CONSENT="${SONUS_ANDROID_RECORDING_PROBE_CONSENT:-}"
CONSENT_PHRASE="I_CONSENT_TO_A_15_SECOND_SONUS_DEVICE_LAB_RECORDING"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/android-recording-$STAMP}"
EVIDENCE_POLICY="$ROOT/scripts/device-lab/evidence-policy.py"
LOGCAT_SINCE_EPOCH="0"
PROBE_PID=""
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

mark_logcat_start() {
  local candidate
  candidate="$(adb_ shell date +%s 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  if [[ ! "$candidate" =~ ^[0-9]+$ ]]; then
    candidate="$(date +%s)"
  fi
  LOGCAT_SINCE_EPOCH="$candidate"
}

recent_logcat() {
  adb_ logcat -d -v epoch 2>/dev/null |
    awk -v since="$LOGCAT_SINCE_EPOCH" \
      '$1 ~ /^[0-9]+([.][0-9]+)?$/ && ($1 + 0) >= (since + 0)'
}

capture_lab_notification() {
  # Android's indentation around NotificationRecord changed across emulator
  # releases. Match the record token at any indentation, then retain enough of
  # only the isolated package's stanza to include title/text extras.
  adb_ shell dumpsys notification --noredact 2>/dev/null |
    awk -v package="$LAB_PKG" '
      /NotificationRecord\(/ {
        keep = index($0, package) > 0
        remaining = keep ? 120 : 0
      }
      keep && remaining > 0 {
        print
        remaining -= 1
      }
    ' > "$EVIDENCE_DIR/notification.txt" || true
}

run_background_probe() (
  set -euo pipefail
  echo "background-probe: waiting for isolated Dart readiness marker"
  local deadline=$((SECONDS + 600))
  until recent_logcat | grep -F 'SONUS_DEVICE_LAB_BACKGROUND_READY' >/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "background-probe: readiness marker did not arrive within 10 minutes" >&2
      exit 1
    fi
    sleep 1
  done

  echo "background-probe: pressing Home during isolated capture"
  adb_ shell input keyevent KEYCODE_HOME
  sleep 4

  adb_ shell dumpsys activity services "$LAB_PKG" \
    > "$EVIDENCE_DIR/services.txt" 2>&1 || true
  adb_ shell appops get "$LAB_PKG" RECORD_AUDIO \
    > "$EVIDENCE_DIR/appops-record-audio.txt" 2>&1 || true
  capture_lab_notification

  local failed=0
  local pid
  pid="$(adb_ shell pidof "$LAB_PKG" 2>/dev/null | tr -d '\r')"
  if [[ -n "$pid" ]]; then
    echo "  ✓ isolated app process remained alive through Home"
  else
    echo "  ✗ isolated app process died after Home" >&2
    failed=1
  fi

  if grep -Fq 'com.pravera.flutter_foreground_task.service.ForegroundService' \
    "$EVIDENCE_DIR/services.txt"; then
    echo "  ✓ microphone foreground service remained registered"
  else
    echo "  ✗ microphone foreground service was missing" >&2
    failed=1
  fi

  if grep -Fq 'Sonus Auris is recording' "$EVIDENCE_DIR/notification.txt"; then
    echo "  ✓ isolated persistent recording notification remained posted"
  else
    echo "  ✗ isolated recording notification was missing" >&2
    failed=1
  fi

  adb_ shell am start -W -n "$LAB_ACTIVITY" \
    -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER \
    > "$EVIDENCE_DIR/foreground-return.txt" 2>&1 || true

  if [[ "$failed" != "0" ]]; then
    exit 1
  fi
  echo "ANDROID ISOLATED BACKGROUND PROBE PASSED"
)

cleanup() {
  local status=$?
  if [[ -n "$PROBE_PID" ]]; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  if [[ -n "$DRIVE_PID" ]]; then
    kill "$DRIVE_PID" 2>/dev/null || true
    wait "$DRIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERIAL" ]]; then
    adb_ shell am force-stop "$LAB_PKG" >/dev/null 2>&1 || true
  fi
  return "$status"
}

main() {
  # The outer evidence pipeline temporarily disables errexit so it can collect
  # all three component statuses. Restore fail-closed behavior inside main.
  set -euo pipefail

  need adb
  need flutter
  need python3
  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "A SHA-256 command (shasum or sha256sum) is required." >&2
    exit 2
  fi
  if [[ ! -f "$EVIDENCE_POLICY" ]]; then
    echo "Evidence policy is missing: $EVIDENCE_POLICY" >&2
    exit 2
  fi
  if [[ "$CONSENT" != "$CONSENT_PHRASE" ]]; then
    cat >&2 <<CONSENT
Refusing to open a real microphone without explicit operator consent.
Set exactly:
  SONUS_ANDROID_RECORDING_PROBE_CONSENT=$CONSENT_PHRASE
The isolated probe records for about 15 seconds, exports no audio, clears its
own WAV/partial files, and never addresses package $PRODUCTION_PKG.
CONSENT
    exit 64
  fi

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

  echo "== build isolated recording candidate =="
  (
    cd "$ROOT"
    flutter pub get
    SONUS_DEVICE_LAB_ANDROID=1 flutter build apk --debug \
      --target="$TARGET" \
      --dart-define=SONUS_DEVICE_LAB_RECORDING_PROBE=true
  )
  if [[ ! -s "$APK" ]]; then
    echo "Isolated APK build did not produce $APK" >&2
    exit 4
  fi

  local observed_package
  observed_package="$(apk_application_id)"
  if [[ "$observed_package" != "$LAB_PKG" ]]; then
    echo "Refusing APK with unexpected application ID '$observed_package'." >&2
    exit 4
  fi
  if [[ "$observed_package" == "$PRODUCTION_PKG" ]]; then
    echo "Refusing to run the recording probe under the production package." >&2
    exit 4
  fi
  printf '%s  %s\n' "$(hash_file "$APK")" "$(basename "$APK")" \
    > "$EVIDENCE_DIR/apk.sha256"
  cat > "$EVIDENCE_DIR/isolation.txt" <<ISOLATION
production_package=$PRODUCTION_PKG
device_lab_package=$LAB_PKG
observed_apk_package=$observed_package
production_package_addressed=false
isolated_deep_link_scheme=sonusauris-device-lab
ISOLATION

  echo "== install and authorize isolated package =="
  adb_ install -r "$APK"
  adb_ shell pm grant "$LAB_PKG" android.permission.RECORD_AUDIO
  adb_ shell pm grant "$LAB_PKG" android.permission.POST_NOTIFICATIONS || true
  if ! adb_ shell dumpsys package "$LAB_PKG" 2>/dev/null |
    tr -d '\r' |
    grep -F 'android.permission.RECORD_AUDIO: granted=true' >/dev/null; then
    echo "Isolated RECORD_AUDIO grant verification failed." >&2
    exit 5
  fi

  mark_logcat_start
  trap cleanup EXIT HUP INT TERM
  run_background_probe &
  PROBE_PID=$!

  echo "== drive isolated real-microphone test =="
  local drive_log="$EVIDENCE_DIR/drive.log"
  (
    set -o pipefail
    (
      cd "$ROOT"
      SONUS_DEVICE_LAB_ANDROID=1 flutter drive \
        --driver=test_driver/integration_test.dart \
        --target="$TARGET" \
        --use-application-binary="$APK" \
        --dart-define=SONUS_DEVICE_LAB_RECORDING_PROBE=true \
        -d "$SERIAL"
    ) 2>&1 | python3 "$EVIDENCE_POLICY" --stream | tee "$drive_log"
  ) &
  DRIVE_PID=$!

  local deadline=$((SECONDS + 900))
  while kill -0 "$DRIVE_PID" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "flutter drive exceeded the 15-minute host deadline" >&2
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
    echo "Isolated Flutter drive/evidence pipeline failed with status $drive_status." >&2
    exit "$drive_status"
  fi

  local background_status=0
  wait "$PROBE_PID" || background_status=$?
  PROBE_PID=""
  if [[ "$background_status" != "0" ]]; then
    echo "Android background lifecycle probe failed with status $background_status." >&2
    exit "$background_status"
  fi

  grep -Fq 'SONUS_DEVICE_LAB_RECORDING_RESULT' "$drive_log"
  grep -Fq 'SONUS_DEVICE_LAB_AUDIO_CLEANUP_PASSED' "$drive_log"
  if recent_logcat | grep -Eq 'FATAL EXCEPTION|am_crash|Process .*device_lab.* has died'; then
    recent_logcat |
      grep -E "$LAB_PKG|FATAL EXCEPTION|AndroidRuntime|am_crash" |
      python3 "$ROOT/scripts/device-lab/bounded-log.py" --max-bytes 524288 \
      > "$EVIDENCE_DIR/crash-focused-logcat.txt" || true
    echo "Fatal Android evidence was observed during the isolated probe." >&2
    exit 7
  fi

  cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=isolated-real-microphone-home-background-foreground-cleanup
explicit_recording_consent=true
package=$LAB_PKG
production_package_addressed=false
record_audio_granted_to_isolated_package=true
persistent_notification_verified=true
shared_logcat_cleared=false
raw_audio_exported=false
probe_audio_cleanup_passed=true
device_lab_package_uninstalled=false
RESULT
  echo "ANDROID ISOLATED RECORDING PROBE PASSED"
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
