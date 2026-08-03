#!/usr/bin/env bash
set -euo pipefail
trap 'echo "permission-denial contract failed at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GRADLE="$ROOT/android/app/build.gradle.kts"
TARGET="$ROOT/integration_test/device_lab_permission_denied_test.dart"
PROBE="$ROOT/scripts/device-lab/android-permission-denial-probe.sh"
EMULATOR_SEQUENCE="$ROOT/scripts/device-lab/android-emulator-probes.sh"
ORCHESTRATOR="$ROOT/scripts/device-lab/macos-end-device-smoke.sh"
WORKFLOW="$ROOT/.github/workflows/device-lab.yml"

for file in "$GRADLE" "$TARGET" "$PROBE" "$EMULATOR_SEQUENCE" "$ORCHESTRATOR" "$WORKFLOW"; do
  [[ -s "$file" ]] || {
    echo "required permission-denial lab file is missing: $file" >&2
    exit 1
  }
done
bash -n "$PROBE"
bash -n "$EMULATOR_SEQUENCE"

# 1. The denial lab has a third Android identity, label, and callback scheme;
# recording and permission lab switches are mutually exclusive and debug-only.
grep -Fq 'System.getenv("SONUS_PERMISSION_LAB_ANDROID") == "1"' "$GRADLE"
grep -Fq '"$productionApplicationId.permission_lab"' "$GRADLE"
grep -Fq 'Sonus Auris Permission Lab' "$GRADLE"
grep -Fq 'sonusauris-permission-lab' "$GRADLE"
grep -Fq 'deviceLabAndroidBuild && permissionLabAndroidBuild' "$GRADLE"
grep -Fq 'permissionLabAndroidBuild && releaseTask != null' "$GRADLE"
grep -Fq 'Permission-lab probes are debug-only' "$GRADLE"
echo 'permission-denial contract group 1 passed: isolated build identity'

# 2. Dart refuses to run outside the compile-time lab gate and proves denial
# produced neither recording state, a foreground service, nor WAV/partial files.
grep -Fq "'SONUS_DEVICE_LAB_PERMISSION_DENIAL'" "$TARGET"
grep -Fq "contains('permission')" "$TARGET"
grep -Fq 'FlutterForegroundTask.isRunningService' "$TARGET"
grep -Fq "endsWith('.wav')" "$TARGET"
grep -Fq "endsWith('.part')" "$TARGET"
grep -Fq 'SONUS_PERMISSION_DENIAL_RESULT' "$TARGET"
grep -Fq 'SONUS_PERMISSION_DENIAL_CLEANUP_PASSED' "$TARGET"
if grep -Eq 'print\([^)]*(localPath|file\.path|readAsBytes)' "$TARGET"; then
  echo 'permission denial test must not print raw paths or bytes' >&2
  exit 1
fi
echo 'permission-denial contract group 2 passed: Dart fail-closed assertions'

# 3. The APK identity is verified before any permission mutation. Production and
# recording-lab package variables may appear in refusal checks/evidence only,
# never as adb targets.
grep -Fq 'observed_package="$(apk_application_id)"' "$PROBE"
grep -Fq 'if [[ "$observed_package" != "$PERMISSION_LAB_PKG" ]]' "$PROBE"
grep -Fq '"$observed_package" == "$PRODUCTION_PKG"' "$PROBE"
grep -Fq '"$observed_package" == "$RECORDING_LAB_PKG"' "$PROBE"
if grep -En 'adb_[[:space:]].*\$(PRODUCTION_PKG|RECORDING_LAB_PKG)|adb[[:space:]].*\$(PRODUCTION_PKG|RECORDING_LAB_PKG)' "$PROBE"; then
  echo 'permission lab may not issue adb commands against production or recording lab' >&2
  exit 1
fi
echo 'permission-denial contract group 3 passed: package targeting'

# 4. A user-fixed denial is created only on the dedicated package and verified
# before Flutter starts. RECORD_AUDIO must never be granted in this harness.
grep -Fq 'pm revoke "$PERMISSION_LAB_PKG" android.permission.RECORD_AUDIO' "$PROBE"
grep -Fq 'pm clear-permission-flags' "$PROBE"
grep -Fq 'pm set-permission-flags' "$PROBE"
grep -Fq 'user-set user-fixed' "$PROBE"
grep -Fq 'android.permission.RECORD_AUDIO: granted=false' "$PROBE"
if grep -Eq 'pm grant .*RECORD_AUDIO' "$PROBE"; then
  echo 'permission denial harness may not grant RECORD_AUDIO' >&2
  exit 1
fi
echo 'permission-denial contract group 4 passed: user-fixed denial ordering'

# 5. Operator defaults remain bounded and non-destructive. The test-owned
# package is force-stopped, but no package data, shared logs, or app is removed.
if grep -En 'adb_?[[:space:]].*(uninstall|pm[[:space:]]+clear([[:space:]]|$))|logcat[[:space:]]+-c' "$PROBE"; then
  echo 'permission denial harness may not uninstall, clear app data, or clear logcat' >&2
  exit 1
fi
grep -Fq 'SECONDS + 480' "$PROBE"
grep -Fq 'production_package_addressed=false' "$PROBE"
grep -Fq 'recording_lab_package_addressed=false' "$PROBE"
grep -Fq 'raw_audio_exported=false' "$PROBE"
grep -Fq 'probe_audio_artifacts=0' "$PROBE"
grep -Fq 'shared_logcat_cleared=false' "$PROBE"
echo 'permission-denial contract group 5 passed: bounded non-destructive defaults'

# 6. A failed Flutter process, stream sanitizer, tee, post-test service/app-op
# assertion, virtual-microphone setup, or sibling probe must propagate instead of
# producing a false-green combined emulator result.
grep -Fq 'set -euo pipefail' "$PROBE"
grep -Fq 'wait "$DRIVE_PID" || drive_status=$?' "$PROBE"
grep -Fq 'pipeline_status=("${PIPESTATUS[@]}")' "$PROBE"
grep -Fq 'stream_status="${pipeline_status[1]}"' "$PROBE"
grep -Fq 'tee_status="${pipeline_status[2]}"' "$PROBE"
grep -Fq 'ForegroundService' "$PROBE"
grep -Fq "RECORD_AUDIO: (allow|foreground)" "$PROBE"
grep -Fq 'permission_status=$?' "$EMULATOR_SEQUENCE"
grep -Fq 'microphone_status=$?' "$EMULATOR_SEQUENCE"
grep -Fq 'recording_status=$?' "$EMULATOR_SEQUENCE"
grep -Fq 'android-permission-denial-probe.sh' "$EMULATOR_SEQUENCE"
grep -Fq 'android-recording-probe.sh' "$EMULATOR_SEQUENCE"
echo 'permission-denial contract group 6 passed: status propagation'

# 7. Mac and hosted labs expose denial as an explicit target. The emulator action
# receives one command and delegates sequencing to a shell file; multiline YAML
# action scripts are forbidden because android-emulator-runner executes their
# continuation lines as independent sh -c commands.
grep -Fq 'SONUS_RUN_ANDROID_PERMISSION_DENIAL_PROBE' "$ORCHESTRATOR"
grep -Fq 'android-permission-denial-probe.sh' "$ORCHESTRATOR"
grep -Fq 'android_permission_denial_probe_opt_in=' "$ORCHESTRATOR"
grep -Fq 'script: bash scripts/device-lab/android-emulator-probes.sh' "$WORKFLOW"
grep -Fq 'SONUS_ANDROID_PERMISSION_EVIDENCE_DIR:' "$WORKFLOW"
grep -Fq 'SONUS_ANDROID_RECORDING_EVIDENCE_DIR:' "$WORKFLOW"
echo 'permission-denial contract group 7 passed: explicit orchestrators'

echo 'isolated Android permission-denial contract passed: 7 groups'
