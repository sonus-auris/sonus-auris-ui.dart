#!/usr/bin/env bash
# Sequence the isolated Android permission-denial and recording probes inside a
# single android-emulator-runner command. The action executes multiline `script`
# entries as separate `sh -c` commands, so status-preserving orchestration lives
# in this checked shell file rather than in workflow YAML continuations.
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PERMISSION_EVIDENCE="${SONUS_ANDROID_PERMISSION_EVIDENCE_DIR:-$ROOT/isolated-android-permission-evidence}"
RECORDING_EVIDENCE="${SONUS_ANDROID_RECORDING_EVIDENCE_DIR:-$ROOT/isolated-android-recording-evidence}"
permission_status=0
microphone_status=0
recording_status=0

mkdir -p "$PERMISSION_EVIDENCE" "$RECORDING_EVIDENCE"

set +e
SONUS_DEVICE_LAB_DIR="$PERMISSION_EVIDENCE" \
  bash "$ROOT/scripts/device-lab/android-permission-denial-probe.sh"
permission_status=$?

# The denial lab never opens the microphone. Enable deterministic virtual input
# only after its result is captured, then run the independently packaged capture
# lab even when denial failed so both evidence sets remain diagnostically useful.
adb emu avd hostmicon
microphone_status=$?
if [[ "$microphone_status" == "0" ]]; then
  SONUS_DEVICE_LAB_DIR="$RECORDING_EVIDENCE" \
    bash "$ROOT/scripts/device-lab/android-recording-probe.sh"
  recording_status=$?
else
  echo "Could not enable deterministic emulator microphone input (status $microphone_status)." >&2
  recording_status=$microphone_status
fi
set -e

cat <<RESULTS
permission_denial_probe_status=$permission_status
virtual_microphone_status=$microphone_status
recording_probe_status=$recording_status
RESULTS

if [[ "$permission_status" != "0" ]]; then
  echo "Permission-denial probe failed with status $permission_status" >&2
  exit "$permission_status"
fi
if [[ "$microphone_status" != "0" ]]; then
  exit "$microphone_status"
fi
if [[ "$recording_status" != "0" ]]; then
  echo "Recording probe failed with status $recording_status" >&2
  exit "$recording_status"
fi

echo "ANDROID ISOLATED DENIAL AND RECORDING PROBES PASSED"
