#!/usr/bin/env bash
# Run a Flutter integration_test on a booted emulator, granting the app the
# runtime permissions it needs BEFORE the test reaches the code that requires
# them. An integration_test process can't tap the OS permission dialog, so we
# grant out-of-band: a background loop watches for the app package and grants
# RECORD_AUDIO + POST_NOTIFICATIONS as soon as it is installed.
#
# When SONUS_BACKGROUND_PROBE=1, a second host-side probe waits for the Dart test
# marker SONUS_BACKGROUND_PROBE_READY, presses Home, verifies the process,
# foreground service, recording notification, and app-ops state while the app is
# actually backgrounded, then brings the existing activity back to the front.
#
# The device integration command first spends several MINUTES building the APK
# before it installs the app, so the granter must be patient and persistent — it
# keeps re-granting for the whole run (Flutter may uninstall/reinstall between
# the app and test APKs) and never gives up early.
#
# Usage: grant-then-run-integration.sh <integration_test/target_test.dart>
set -euo pipefail

TARGET="${1:?usage: grant-then-run-integration.sh <integration_test target>}"
PKG=com.ores.sonus_auris
ACTIVITY="$PKG/.MainActivity"
APP_BINARY=build/app/outputs/flutter-apk/app-debug.apk
BACKGROUND_PROBE_ENABLED="${SONUS_BACKGROUND_PROBE:-0}"
BACKGROUND_EVIDENCE_DIR="${BACKGROUND_EVIDENCE_DIR:-$PWD/background-recording-evidence}"
PROBE_PID=""

adb wait-for-device
DEVICE_ID="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
if [[ -z "$DEVICE_ID" ]]; then
  echo "recording-integration: no ready Android device found"
  exit 1
fi
if [[ ! -f "$APP_BINARY" ]]; then
  echo "recording-integration: prebuilt integration APK is missing: $APP_BINARY"
  exit 1
fi

# Install the integration-target APK before flutter drive launches it. This
# gives us a deterministic window to grant and verify RECORD_AUDIO without an
# Android permission dialog racing the Dart test process.
adb -s "$DEVICE_ID" install -r "$APP_BINARY" >/dev/null
adb -s "$DEVICE_ID" shell pm grant "$PKG" android.permission.RECORD_AUDIO
adb -s "$DEVICE_ID" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS || true
if ! adb -s "$DEVICE_ID" shell dumpsys package "$PKG" 2>/dev/null |
  tr -d '\r' |
  grep -F 'android.permission.RECORD_AUDIO: granted=true' >/dev/null; then
  echo "recording-integration: RECORD_AUDIO grant verification failed"
  exit 1
fi
echo "recording-integration: RECORD_AUDIO grant verified before launch"

# Persistent background granter: for the whole run, whenever the package is
# present, (re)grant the runtime perms. Cheap and idempotent; killed at the end.
(
  while true; do
    if adb -s "$DEVICE_ID" shell pm list packages 2>/dev/null |
      tr -d '\r' | grep -F "package:$PKG" >/dev/null; then
      adb -s "$DEVICE_ID" shell pm grant \
        "$PKG" android.permission.RECORD_AUDIO 2>/dev/null || true
      adb -s "$DEVICE_ID" shell pm grant \
        "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
    fi
    sleep 2
  done
) &
GRANTER=$!

run_background_probe() (
  set -euo pipefail
  mkdir -p "$BACKGROUND_EVIDENCE_DIR"
  exec > >(tee "$BACKGROUND_EVIDENCE_DIR/probe.log") 2>&1

  restore_foreground() {
    adb -s "$DEVICE_ID" shell am start -W -n "$ACTIVITY" \
      -a android.intent.action.MAIN \
      -c android.intent.category.LAUNCHER \
      >"$BACKGROUND_EVIDENCE_DIR/relaunch.txt" 2>&1 || true
  }
  trap restore_foreground EXIT

  echo "background-probe: waiting for device-side readiness marker"
  deadline=$((SECONDS + 600))
  until adb -s "$DEVICE_ID" logcat -d 2>/dev/null |
    grep -F 'SONUS_BACKGROUND_PROBE_READY' >/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "background-probe: readiness marker did not arrive within 10 minutes"
      exit 1
    fi
    sleep 1
  done

  echo "background-probe: pressing Home while mic capture is live"
  adb -s "$DEVICE_ID" shell input keyevent 3
  sleep 4

  adb -s "$DEVICE_ID" shell dumpsys activity services "$PKG" \
    >"$BACKGROUND_EVIDENCE_DIR/services.txt" 2>&1 || true
  adb -s "$DEVICE_ID" shell dumpsys notification --noredact \
    >"$BACKGROUND_EVIDENCE_DIR/notifications.txt" 2>&1 || true
  adb -s "$DEVICE_ID" shell appops get "$PKG" RECORD_AUDIO \
    >"$BACKGROUND_EVIDENCE_DIR/appops-record-audio.txt" 2>&1 || true
  adb -s "$DEVICE_ID" shell dumpsys activity activities \
    >"$BACKGROUND_EVIDENCE_DIR/activities.txt" 2>&1 || true
  adb -s "$DEVICE_ID" exec-out screencap -p \
    >"$BACKGROUND_EVIDENCE_DIR/home-screen.png" 2>/dev/null || true

  failed=0
  pid="$(adb -s "$DEVICE_ID" shell pidof "$PKG" | tr -d '\r')"
  if [[ -n "$pid" ]]; then
    echo "  ✓ app process remained alive in background (pid $pid)"
  else
    echo "  ✗ app process died after Home"
    failed=1
  fi

  if grep -Fq 'com.pravera.flutter_foreground_task.service.ForegroundService' \
    "$BACKGROUND_EVIDENCE_DIR/services.txt"; then
    echo "  ✓ microphone foreground service remained registered"
  else
    echo "  ✗ foreground service missing while app was backgrounded"
    failed=1
  fi

  if grep -Fq 'Sonus Auris is recording' \
    "$BACKGROUND_EVIDENCE_DIR/notifications.txt"; then
    echo "  ✓ persistent recording notification remained posted"
  else
    echo "  ✗ recording notification missing while app was backgrounded"
    failed=1
  fi

  if grep -Eq 'foregroundServiceType=(0x00000080|128)|mForegroundServiceType=(0x00000080|128)' \
    "$BACKGROUND_EVIDENCE_DIR/services.txt"; then
    echo "  ✓ Android reports microphone foreground-service type"
  else
    echo "  ! service-type field was not present in this emulator dumpsys format"
  fi

  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  echo "BACKGROUND RECORDING HOST PROBE PASSED"
)

cleanup() {
  local status=$?
  kill "$GRANTER" 2>/dev/null || true
  if [[ -n "$PROBE_PID" ]]; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "recording-integration: device diagnostics after failure"
    adb -s "$DEVICE_ID" shell dumpsys activity activities 2>/dev/null |
      awk '/mResumedActivity|mFocusedApp/ { print }'
    adb -s "$DEVICE_ID" logcat -d 2>/dev/null |
      awk -v package="$PKG" '
        index($0, package) || /AndroidRuntime/ || /flutter/ { lines[++count]=$0 }
        END {
          start = count > 120 ? count - 119 : 1
          for (i = start; i <= count; i++) print lines[i]
        }
      '
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ "$BACKGROUND_PROBE_ENABLED" == "1" ]]; then
  mkdir -p "$BACKGROUND_EVIDENCE_DIR"
  adb -s "$DEVICE_ID" logcat -c
  run_background_probe &
  PROBE_PID=$!
fi

# `flutter test` built and installed the APK on CI but could then wait forever
# for its device-side test connection. The integration-test driver is the
# explicit, supported device protocol and gives us a bounded host handshake.
DRIVE=(
  flutter drive
  --driver=test_driver/integration_test.dart
  --target="$TARGET"
  --use-application-binary="$APP_BINARY"
  -d "$DEVICE_ID"
)
if command -v timeout >/dev/null 2>&1; then
  timeout 12m "${DRIVE[@]}"
else
  "${DRIVE[@]}"
fi

if [[ -n "$PROBE_PID" ]]; then
  wait "$PROBE_PID"
  PROBE_PID=""
fi
