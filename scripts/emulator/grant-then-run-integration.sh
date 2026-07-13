#!/usr/bin/env bash
# Run a Flutter integration_test on a booted emulator, granting the app the
# runtime permissions it needs BEFORE the test reaches the code that requires
# them. An integration_test process can't tap the OS permission dialog, so we
# grant out-of-band: a background loop watches for the app package and grants
# RECORD_AUDIO + POST_NOTIFICATIONS as soon as it is installed.
#
# `flutter test integration_test` first spends several MINUTES building the
# instrumentation APK before it installs the app, so the granter must be patient
# and PERSISTENT — it keeps re-granting for the whole run (flutter may
# uninstall/reinstall between the app and test APKs) and never gives up early.
#
# Usage: grant-then-run-integration.sh <integration_test/target_test.dart>
set -euo pipefail

TARGET="${1:?usage: grant-then-run-integration.sh <integration_test target>}"
PKG=com.ores.audio_dashcam

adb wait-for-device

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
trap 'kill "$GRANTER" 2>/dev/null || true' EXIT

flutter test "$TARGET"
