#!/usr/bin/env bash
set -euo pipefail
trap 'echo "iOS permission-denial contract failed at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TARGET="$ROOT/integration_test/device_lab_ios_permission_denied_test.dart"
PROBE="$ROOT/scripts/device-lab/ios-permission-denial-probe.sh"
WORKFLOW="$ROOT/.github/workflows/ios-permission-lab.yml"
ORCHESTRATOR="$ROOT/scripts/device-lab/macos-end-device-smoke.sh"

for file in "$TARGET" "$PROBE" "$WORKFLOW" "$ORCHESTRATOR"; do
  [[ -s "$file" ]] || {
    echo "required iOS permission-lab file is missing: $file" >&2
    exit 1
  }
done
bash -n "$PROBE"

# 1. Dart refuses to run outside the compile-time iOS gate and requires an
# actionable permission error, idle recorder state, and zero WAV/partial files.
grep -Fq "'SONUS_IOS_PERMISSION_DENIAL_LAB'" "$TARGET"
grep -Fq 'Platform.isIOS' "$TARGET"
grep -Fq "contains('permission')" "$TARGET"
grep -Fq "endsWith('.wav')" "$TARGET"
grep -Fq "endsWith('.part')" "$TARGET"
grep -Fq 'SONUS_IOS_PERMISSION_DENIAL_RESULT' "$TARGET"
grep -Fq 'SONUS_IOS_PERMISSION_DENIAL_CLEANUP_PASSED' "$TARGET"
if grep -Eq 'print\([^)]*(localPath|file\.path|readAsBytes)' "$TARGET"; then
  echo 'iOS permission denial target must not print raw paths or bytes' >&2
  exit 1
fi
echo 'iOS permission contract group 1 passed: Dart fail-closed behavior'

# 2. The host creates one simulator before mutating microphone privacy and uses
# only the UUID returned by that create call for every device-specific command.
grep -Fq 'CREATED_UDID="$(xcrun simctl create' "$PROBE"
grep -Fq 'xcrun simctl privacy "$CREATED_UDID" revoke microphone "$BUNDLE_ID"' "$PROBE"
create_line="$(grep -n 'CREATED_UDID="$(xcrun simctl create' "$PROBE" | cut -d: -f1)"
privacy_line="$(grep -n 'simctl privacy "$CREATED_UDID" revoke microphone' "$PROBE" | cut -d: -f1)"
[[ -n "$create_line" && -n "$privacy_line" ]]
(( create_line < privacy_line ))
if grep -Eq 'IOS_SIMULATOR_UDID|simctl booted|[[:space:]]booted[[:space:]]' "$PROBE"; then
  echo 'disposable permission lab may not select or address an existing booted simulator' >&2
  exit 1
fi
grep -Fq 'existing_simulator_addressed=false' "$PROBE"
grep -Fq 'physical_iphone_addressed=false' "$PROBE"
echo 'iOS permission contract group 2 passed: disposable simulator targeting'

# 3. Runtime selection is compatibility-capped instead of blindly choosing the
# newest installed runtime. Flutter 3.44.2 failed to attach on hosted iOS 26.2,
# so the default chooses the newest available iOS runtime at or below major 18.
# The device type must come from that runtime's own supportedDeviceTypes list,
# and Flutter must discover the created UUID as one iOS emulator before build.
grep -Fq 'SONUS_IOS_PERMISSION_LAB_MAX_RUNTIME_MAJOR:-18' "$PROBE"
grep -Fq 'SONUS_IOS_PERMISSION_LAB_RUNTIME_MAJOR' "$PROBE"
grep -Fq 'compatible = [item for item in choices if item[0] <= max_major]' "$PROBE"
grep -Fq 'No compatible iOS Simulator runtime' "$PROBE"
grep -Fq 'runtime.get("supportedDeviceTypes", [])' "$PROBE"
grep -Fq 'family != "iPhone"' "$PROBE"
grep -Fq 'runtime-owned compatibility list' "$PROBE"
grep -Fq 'verify_flutter_device_visibility' "$PROBE"
grep -Fq 'Flutter did not discover the test-created simulator exactly once' "$PROBE"
grep -Fq 'target_emulator=true' "$PROBE"
grep -Fq 'runtime_compatibility_cap=$MAX_RUNTIME_MAJOR' "$PROBE"
echo 'iOS permission contract group 3 passed: runtime-owned device compatibility and Flutter discovery'

# 4. Cleanup may terminate, shut down, and delete only the test-created UUID.
# It may not erase a simulator, delete all unavailable devices, or touch a
# physical iPhone. Success and failure paths both write deletion evidence.
grep -Fq 'simctl delete "$CREATED_UDID"' "$PROBE"
grep -Fq 'SIMULATOR_DELETED=true' "$PROBE"
grep -Fq 'write_cleanup_evidence' "$PROBE"
grep -Fq 'simulator_deleted=$SIMULATOR_DELETED' "$PROBE"
grep -Fq 'capture_simulator_logs failure 15m' "$PROBE"
if grep -En 'simctl erase|simctl delete unavailable|simctl delete all|devicectl|ios-deploy' "$PROBE"; then
  echo 'iOS permission lab contains a broad or physical-device mutation' >&2
  exit 1
fi
echo 'iOS permission contract group 4 passed: bounded simulator cleanup'

# 5. Flutter drive normally uninstalls its target. The probe must keep the app
# installed, prove an app container before and after drive, and only then delete
# the disposable device.
grep -Fq -- '--keep-app-running' "$PROBE"
[[ "$(grep -Fc 'simctl get_app_container "$CREATED_UDID" "$BUNDLE_ID" app' "$PROBE")" -ge 2 ]]
grep -Fq 'pre_drive_app_container_fingerprint=' "$PROBE"
grep -Fq 'installed_app_container_fingerprint=' "$PROBE"
grep -Fq 'flutter_drive_keep_app_running=true' "$PROBE"
grep -Fq 'app_installation_verified_before_simulator_deletion=true' "$PROBE"
container_line="$(grep -n 'simctl get_app_container "$CREATED_UDID"' "$PROBE" | tail -n 1 | cut -d: -f1)"
delete_line="$(grep -n '^  delete_created_simulator$' "$PROBE" | tail -n 1 | cut -d: -f1)"
[[ -n "$container_line" && -n "$delete_line" ]]
(( container_line < delete_line ))
echo 'iOS permission contract group 5 passed: installation retention proof'

# 6. A failed drive, live sanitizer, tee, fatal-log assertion, or simulator
# deletion must propagate. Timeout and failed-attach paths collect bounded logs
# before deletion; raw audio remains forbidden.
grep -Fq 'SONUS_IOS_PERMISSION_DRIVE_TIMEOUT_SECONDS:-480' "$PROBE"
grep -Fq 'SECONDS + DRIVE_TIMEOUT_SECONDS' "$PROBE"
grep -Fq 'capture_simulator_logs drive-timeout 15m' "$PROBE"
grep -Fq 'capture_simulator_logs drive-failure 15m' "$PROBE"
grep -Fq 'wait "$DRIVE_PID" || drive_status=$?' "$PROBE"
grep -Fq 'pipeline_status=("${PIPESTATUS[@]}")' "$PROBE"
grep -Fq 'stream_status="${pipeline_status[1]}"' "$PROBE"
grep -Fq 'tee_status="${pipeline_status[2]}"' "$PROBE"
grep -Fq 'bounded-log.py' "$PROBE"
grep -Fq 'raw_audio_exported=false' "$PROBE"
grep -Fq 'probe_audio_artifacts=0' "$PROBE"
echo 'iOS permission contract group 6 passed: fail-closed evidence pipeline'

# 7. The hosted workflow and one-command Mac lab run the same checked script.
# The hosted gate pins the compatibility cap, formats the Dart target, sanitizes
# evidence even on failure, and uploads only policy-approved output.
grep -Fq 'bash tests/ci/ios-permission-denial.test.sh' "$WORKFLOW"
grep -Fq 'dart format integration_test/device_lab_ios_permission_denied_test.dart' "$WORKFLOW"
grep -Fq 'SONUS_IOS_PERMISSION_LAB_MAX_RUNTIME_MAJOR:' "$WORKFLOW"
grep -Fq 'bash scripts/device-lab/ios-permission-denial-probe.sh' "$WORKFLOW"
grep -Fq 'evidence-policy.py --redact' "$WORKFLOW"
grep -Fq 'sonus-ios-simulator-permission-denial-evidence' "$WORKFLOW"
grep -Fq 'SONUS_RUN_IOS_PERMISSION_DENIAL_PROBE' "$ORCHESTRATOR"
grep -Fq 'ios-permission-denial-probe.sh' "$ORCHESTRATOR"
grep -Fq 'ios_permission_denial_probe_opt_in=' "$ORCHESTRATOR"
echo 'iOS permission contract group 7 passed: hosted and Mac orchestrators'

echo 'disposable iOS Simulator permission-denial contract passed: 7 groups'
