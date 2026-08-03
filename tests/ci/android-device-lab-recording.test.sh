#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GRADLE="$ROOT/android/app/build.gradle.kts"
MANIFEST="$ROOT/android/app/src/main/AndroidManifest.xml"
TARGET="$ROOT/integration_test/device_lab_recording_probe_test.dart"
PROBE="$ROOT/scripts/device-lab/android-recording-probe.sh"
ORCHESTRATOR="$ROOT/scripts/device-lab/macos-end-device-smoke.sh"
BOUNDED_LOG="$ROOT/scripts/device-lab/bounded-log.py"

for file in "$GRADLE" "$MANIFEST" "$TARGET" "$PROBE" "$ORCHESTRATOR" "$BOUNDED_LOG"; do
  [[ -s "$file" ]] || {
    echo "required isolated recording-probe file is missing: $file" >&2
    exit 1
  }
done

bash -n "$PROBE"
python3 -m py_compile "$BOUNDED_LOG"
python3 "$BOUNDED_LOG" --self-test

# 1. Gradle must switch to a non-production app sandbox only under the explicit
# environment gate, and that identity must remain release-ineligible.
grep -Fq 'System.getenv("SONUS_DEVICE_LAB_ANDROID") == "1"' "$GRADLE"
grep -Fq '"$productionApplicationId.device_lab"' "$GRADLE"
grep -Fq 'if (deviceLabAndroidBuild && releaseTask != null)' "$GRADLE"
grep -Fq 'Device-lab recording probes are debug-only' "$GRADLE"

# 2. The visible label and all custom-scheme handlers must be placeholders so
# the isolated package cannot impersonate production auth/invite/OAuth links.
grep -Fq 'android:label="${sonusAppLabel}"' "$MANIFEST"
[[ "$(grep -Fc 'android:scheme="${sonusUriScheme}"' "$MANIFEST")" == "3" ]]
grep -Fq 'sonusauris-device-lab' "$GRADLE"

# 3. Dart capture is compile-time gated and emits only bounded metrics plus an
# explicit proof that its isolated WAV/partial files were removed.
grep -Fq "bool.fromEnvironment(" "$TARGET"
grep -Fq "'SONUS_DEVICE_LAB_RECORDING_PROBE'" "$TARGET"
grep -Fq 'SONUS_DEVICE_LAB_RECORDING_RESULT' "$TARGET"
grep -Fq 'SONUS_DEVICE_LAB_AUDIO_CLEANUP_PASSED' "$TARGET"
grep -Fq 'await index.clearAll();' "$TARGET"
if grep -Eq 'print\([^)]*(localPath|file\.path|readAsBytes)' "$TARGET"; then
  echo 'recording probe must not print raw paths or audio bytes' >&2
  exit 1
fi

# 4. Host automation requires an exact human-readable consent phrase before any
# build, install, permission grant, foreground-service start, or microphone use.
grep -Fq 'I_CONSENT_TO_A_15_SECOND_SONUS_DEVICE_LAB_RECORDING' "$PROBE"
consent_line="$(grep -n 'if \[\[ "$CONSENT" != "$CONSENT_PHRASE" \]\]' "$PROBE" | cut -d: -f1)"
build_line="$(grep -n 'flutter build apk --debug' "$PROBE" | cut -d: -f1)"
grant_line="$(grep -n 'pm grant "$LAB_PKG" android.permission.RECORD_AUDIO' "$PROBE" | cut -d: -f1)"
[[ -n "$consent_line" && -n "$build_line" && -n "$grant_line" ]]
(( consent_line < build_line && consent_line < grant_line ))

# 5. APK identity is verified before install; the production ID is explicitly
# refused and never appears as an adb target.
grep -Fq 'observed_package="$(apk_application_id)"' "$PROBE"
grep -Fq 'if [[ "$observed_package" != "$LAB_PKG" ]]' "$PROBE"
grep -Fq 'if [[ "$observed_package" == "$PRODUCTION_PKG" ]]' "$PROBE"
if grep -En 'adb_[[:space:]].*\$PRODUCTION_PKG|adb[[:space:]].*\$PRODUCTION_PKG' "$PROBE"; then
  echo 'device-lab probe must never issue adb commands against production' >&2
  exit 1
fi

# 6. Operator hardware defaults remain non-destructive. The isolated package is
# force-stopped, but neither app is uninstalled/cleared and shared logcat remains.
if grep -En 'adb_?[[:space:]].*(uninstall|pm clear)|logcat[[:space:]]+-c' "$PROBE"; then
  echo 'isolated recording probe may not uninstall, clear app data, or clear logcat' >&2
  exit 1
fi
grep -Fq 'shared_logcat_cleared=false' "$PROBE"
grep -Fq 'raw_audio_exported=false' "$PROBE"
grep -Fq 'production_package_addressed=false' "$PROBE"
grep -Fq 'bounded-log.py" --max-bytes 524288' "$PROBE"
if grep -Fq 'tail -n 160' "$PROBE"; then
  echo 'recording crash evidence must preserve startup and terminal context' >&2
  exit 1
fi

# 7. Real background behavior is host-driven and every asynchronous/pipeline
# failure is propagated. This guards the false-green case where a missing
# notification was logged but set +e allowed result.txt to claim success.
grep -Fq 'SONUS_DEVICE_LAB_BACKGROUND_READY' "$PROBE"
grep -Fq 'input keyevent KEYCODE_HOME' "$PROBE"
grep -Fq 'flutter_foreground_task.service.ForegroundService' "$PROBE"
grep -Fq 'Sonus Auris is recording' "$PROBE"
grep -Fq 'persistent_notification_verified=true' "$PROBE"
grep -Fq 'wait "$PROBE_PID" || background_status=$?' "$PROBE"
grep -Fq 'if [[ "$background_status" != "0" ]]' "$PROBE"
grep -Fq 'pipeline_status=("${PIPESTATUS[@]}")' "$PROBE"
grep -Fq 'stream_status="${pipeline_status[1]}"' "$PROBE"
grep -Fq 'tee_status="${pipeline_status[2]}"' "$PROBE"
main_line="$(grep -n '^main() {' "$PROBE" | cut -d: -f1)"
[[ -n "$main_line" ]]
sed -n "$((main_line + 1)),$((main_line + 8))p" "$PROBE" |
  grep -Fq 'set -euo pipefail'
grep -Fq '/NotificationRecord\(/ {' "$PROBE"
if grep -Fq '/^  NotificationRecord\(/' "$PROBE"; then
  echo 'notification extraction must not depend on Android indentation' >&2
  exit 1
fi

# 8. The Mac orchestrator exposes the probe only as a separate opt-in target.
grep -Fq 'SONUS_RUN_ANDROID_RECORDING_PROBE' "$ORCHESTRATOR"
grep -Fq 'android-recording-probe.sh' "$ORCHESTRATOR"

echo 'isolated Android device-lab recording contract passed: 8 groups'
