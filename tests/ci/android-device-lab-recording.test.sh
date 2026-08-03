#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GRADLE="$ROOT/android/app/build.gradle.kts"
MANIFEST="$ROOT/android/app/src/main/AndroidManifest.xml"
TARGET="$ROOT/integration_test/device_lab_recording_probe_test.dart"
SIGNAL_SUPPORT="$ROOT/integration_test/support/pcm16_signal.dart"
SIGNAL_TEST="$ROOT/test/device_lab_pcm16_signal_test.dart"
PROBE="$ROOT/scripts/device-lab/android-recording-probe.sh"
ORCHESTRATOR="$ROOT/scripts/device-lab/macos-end-device-smoke.sh"
BOUNDED_LOG="$ROOT/scripts/device-lab/bounded-log.py"

for file in \
  "$GRADLE" \
  "$MANIFEST" \
  "$TARGET" \
  "$SIGNAL_SUPPORT" \
  "$SIGNAL_TEST" \
  "$PROBE" \
  "$ORCHESTRATOR" \
  "$BOUNDED_LOG"; do
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

# 3. Dart capture is compile-time gated, validates both live and persisted PCM,
# and emits only bounded metrics plus proof its WAV/partial files were removed.
grep -Fq "'SONUS_DEVICE_LAB_RECORDING_PROBE'" "$TARGET"
grep -Fq "'SONUS_DEVICE_LAB_REQUIRE_NONZERO_AUDIO'" "$TARGET"
grep -Fq 'summarizePcm16Signal(bytes, payloadOffset: 44).observed()' "$TARGET"
grep -Fq 'summarizePcm16Signal(' "$TARGET"
grep -Fq 'signalRequired=$_requireNonzeroAudio' "$TARGET"
grep -Fq 'signalObserved=$signalObserved' "$TARGET"
grep -Fq 'SONUS_DEVICE_LAB_AUDIO_CLEANUP_PASSED' "$TARGET"
grep -Fq 'await index.clearAll();' "$TARGET"
grep -Fq 'minimumNonTrivialSamples = 64' "$SIGNAL_SUPPORT"
grep -Fq 'one spike cannot satisfy the sustained-input contract' "$SIGNAL_TEST"
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

# 6. The production package and shared device state remain untouched. Clearing
# is allowed only for the dedicated test package so failed audio cannot persist.
if grep -En 'adb_?[[:space:]].*uninstall|logcat[[:space:]]+-c' "$PROBE"; then
  echo 'isolated recording probe may not uninstall packages or clear logcat' >&2
  exit 1
fi
[[ "$(grep -Ec 'pm clear' "$PROBE")" == "1" ]]
grep -Fq 'pm clear "$LAB_PKG"' "$PROBE"
grep -Fq 'isolated_package_data_cleared_before_probe=' "$PROBE"
grep -Fq 'isolated_package_data_cleared_after_probe=' "$PROBE"
grep -Fq 'raw_audio_retained_on_device=false' "$PROBE"
grep -Fq 'shared_logcat_cleared=false' "$PROBE"
grep -Fq 'raw_audio_exported=false' "$PROBE"
grep -Fq 'production_package_addressed=false' "$PROBE"
grep -Fq 'bounded-log.py" --max-bytes 524288' "$PROBE"
if grep -Fq 'tail -n 160' "$PROBE"; then
  echo 'recording crash evidence must preserve startup and terminal context' >&2
  exit 1
fi

# 7. Real background behavior is host-driven and the app-op must be actively
# running while the isolated recorder is behind Home.
grep -Fq 'SONUS_DEVICE_LAB_BACKGROUND_READY' "$PROBE"
grep -Fq 'input keyevent KEYCODE_HOME' "$PROBE"
grep -Fq 'flutter_foreground_task.service.ForegroundService' "$PROBE"
grep -Fq 'cmd appops get "$LAB_PKG" RECORD_AUDIO' "$PROBE"
grep -Fq "RECORD_AUDIO: (allow|foreground).*\\(running\\)" "$PROBE"
grep -Fq 'record_audio_appop_running_while_backgrounded=true' "$PROBE"
grep -Fq 'Sonus Auris is recording' "$PROBE"

# 8. Physical targets require sustained non-zero PCM in both live and persisted
# buffers; hosted emulators exercise lifecycle/cleanup without making that claim.
grep -Fq 'local require_signal=true' "$PROBE"
grep -Fq 'if [[ "$qemu" == "1" ]]' "$PROBE"
[[ "$(grep -Fc 'SONUS_DEVICE_LAB_REQUIRE_NONZERO_AUDIO=$require_signal' "$PROBE")" == "2" ]]
grep -Fq 'signalRequired=true signalObserved=true' "$PROBE"
grep -Fq 'nonzero_pcm_required=$require_signal' "$PROBE"
grep -Fq 'nonzero_pcm_observed=$signal_observed' "$PROBE"

# 9. The Mac orchestrator exposes the probe only as a separate opt-in target.
grep -Fq 'SONUS_RUN_ANDROID_RECORDING_PROBE' "$ORCHESTRATOR"
grep -Fq 'android-recording-probe.sh' "$ORCHESTRATOR"

# 10. The committed PCM helper has a standalone Flutter unit-test surface.
grep -Fq 'silent PCM remains below the physical signal threshold' "$SIGNAL_TEST"
grep -Fq 'sustained non-trivial PCM is recognized' "$SIGNAL_TEST"
grep -Fq 'WAV headers are excluded' "$SIGNAL_TEST"
grep -Fq 'misaligned or invalid thresholds fail closed' "$SIGNAL_TEST"

echo 'isolated Android device-lab recording contract passed: 10 groups'
