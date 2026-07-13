#!/usr/bin/env bash
# Run a Flutter integration_test on a booted emulator, granting the app the
# runtime permissions it needs BEFORE the test reaches the code that requires
# them. An integration_test process can't tap the OS permission dialog, so we
# grant out-of-band: a background loop watches for the app package and grants
# RECORD_AUDIO + POST_NOTIFICATIONS as soon as it is installed.
#
# The device integration command first spends several MINUTES building the APK
# before it installs the app, so the granter must be patient
# and PERSISTENT — it keeps re-granting for the whole run (flutter may
# uninstall/reinstall between the app and test APKs) and never gives up early.
#
# Usage: grant-then-run-integration.sh <integration_test/target_test.dart>
set -euo pipefail

TARGET="${1:?usage: grant-then-run-integration.sh <integration_test target>}"
PKG=com.ores.audio_dashcam

adb wait-for-device
DEVICE_ID="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
if [[ -z "$DEVICE_ID" ]]; then
  echo "recording-integration: no ready Android device found"
  exit 1
fi

# Persistent background granter: for the whole run, whenever the package is
# present, (re)grant the runtime perms. Cheap and idempotent; killed at the end.
(
  while true; do
    if adb shell pm list packages 2>/dev/null | tr -d '\r' | grep -q "package:$PKG"; then
      adb shell pm grant "$PKG" android.permission.RECORD_AUDIO 2>/dev/null || true
      adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
    fi
    sleep 2
  done
) &
GRANTER=$!
cleanup() {
  local status=$?
  kill "$GRANTER" 2>/dev/null || true
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

# `flutter test` built and installed the APK on CI but could then wait forever
# for its device-side test connection. The integration-test driver is the
# explicit, supported device protocol and gives us a bounded host handshake.
DRIVE=(
  flutter drive
  --driver=test_driver/integration_test.dart
  --target="$TARGET"
  -d "$DEVICE_ID"
)
if command -v timeout >/dev/null 2>&1; then
  timeout 12m "${DRIVE[@]}"
else
  "${DRIVE[@]}"
fi
