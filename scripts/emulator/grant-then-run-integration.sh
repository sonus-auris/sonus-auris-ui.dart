#!/usr/bin/env bash
# Run a Flutter integration_test on a booted emulator, granting the app the
# runtime permissions it needs BEFORE the test reaches the code that requires
# them. An integration_test process can't tap the OS permission dialog, so we
# grant out-of-band: a background loop watches for the app package to be
# installed (flutter test installs it) and grants RECORD_AUDIO + POST_NOTIFICATIONS
# the instant it appears — well before recorder.start() runs.
#
# Usage: grant-then-run-integration.sh <integration_test/target_test.dart>
set -euo pipefail

TARGET="${1:?usage: grant-then-run-integration.sh <integration_test target>}"
PKG=com.ores.audio_dashcam

adb wait-for-device

# Background granter: keep trying until the package exists and grants succeed.
(
  for _ in $(seq 1 180); do
    if adb shell pm list packages 2>/dev/null | tr -d '\r' | grep -q "package:$PKG"; then
      adb shell pm grant "$PKG" android.permission.RECORD_AUDIO 2>/dev/null || true
      adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
      # Confirm the mic grant actually stuck before exiting.
      if adb shell dumpsys package "$PKG" 2>/dev/null | tr -d '\r' \
           | grep -q "android.permission.RECORD_AUDIO: granted=true"; then
        echo "[granter] RECORD_AUDIO granted to $PKG"
        exit 0
      fi
    fi
    sleep 1
  done
  echo "[granter] gave up waiting for $PKG"
) &
GRANTER=$!

# Re-grant on every reinstall flutter might do, harmless if already granted.
flutter test "$TARGET"
STATUS=$?

kill "$GRANTER" 2>/dev/null || true
exit $STATUS
