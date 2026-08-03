#!/usr/bin/env bash
# Disposable iOS Simulator microphone-permission denial probe. This script
# creates its own simulator, never addresses an existing simulator or physical
# iPhone, and deletes only the simulator UUID returned by its own create call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUNDLE_ID="com.ores.audioDashcam"
TARGET="integration_test/device_lab_ios_permission_denied_test.dart"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/ios-permission-$STAMP}"
EVIDENCE_POLICY="$ROOT/scripts/device-lab/evidence-policy.py"
BOUNDED_LOG="$ROOT/scripts/device-lab/bounded-log.py"
MAX_RUNTIME_MAJOR="${SONUS_IOS_PERMISSION_LAB_MAX_RUNTIME_MAJOR:-18}"
REQUESTED_RUNTIME_MAJOR="${SONUS_IOS_PERMISSION_LAB_RUNTIME_MAJOR:-}"
DRIVE_TIMEOUT_SECONDS="${SONUS_IOS_PERMISSION_DRIVE_TIMEOUT_SECONDS:-480}"
CREATED_UDID=""
DRIVE_PID=""
SIMULATOR_DELETED=false
mkdir -p "$EVIDENCE_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

hash_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}

select_runtime() {
  xcrun simctl list runtimes available --json | \
    MAX_MAJOR="$MAX_RUNTIME_MAJOR" REQUESTED_MAJOR="$REQUESTED_RUNTIME_MAJOR" python3 -c '
import json
import os
import re
import sys

payload = json.load(sys.stdin)
max_major = int(os.environ["MAX_MAJOR"])
requested_text = os.environ.get("REQUESTED_MAJOR", "").strip()
requested_major = int(requested_text) if requested_text else None
choices = []
for runtime in payload.get("runtimes", []):
    if not runtime.get("isAvailable", True):
        continue
    identifier = str(runtime.get("identifier", ""))
    name = str(runtime.get("name", ""))
    if "iOS" not in identifier and not name.startswith("iOS"):
        continue
    version = tuple(
        int(part)
        for part in re.findall(r"\d+", str(runtime.get("version", "0")))
    )
    major = version[0] if version else 0
    choices.append((major, version, identifier, name))

if requested_major is not None:
    compatible = [item for item in choices if item[0] == requested_major]
    policy = f"exact-major-{requested_major}"
else:
    compatible = [item for item in choices if item[0] <= max_major]
    policy = f"highest-major-at-or-below-{max_major}"

if not compatible:
    available = ", ".join(sorted(item[3] for item in choices)) or "none"
    raise SystemExit(
        f"No compatible iOS Simulator runtime for {policy}; available: {available}"
    )
major, version, identifier, name = sorted(compatible, key=lambda item: (item[0], item[1]))[-1]
print(identifier)
print(name)
print(major)
print(".".join(str(part) for part in version))
print(policy)
'
}

select_device_type() {
  local runtime_id="$1"
  xcrun simctl list runtimes available --json | \
    RUNTIME_ID="$runtime_id" python3 -c '
import json
import os
import re
import sys

payload = json.load(sys.stdin)
runtime_id = os.environ["RUNTIME_ID"]
runtime = next(
    (
        item
        for item in payload.get("runtimes", [])
        if str(item.get("identifier", "")) == runtime_id
    ),
    None,
)
if runtime is None:
    raise SystemExit("Selected iOS runtime disappeared before device creation")
choices = []
for device in runtime.get("supportedDeviceTypes", []):
    name = str(device.get("name", ""))
    identifier = str(device.get("identifier", ""))
    family = str(device.get("productFamily", ""))
    if family != "iPhone" and not name.startswith("iPhone"):
        continue
    numbers = tuple(int(part) for part in re.findall(r"\d+", name))
    is_se = 1 if "SE" in name else 0
    choices.append((is_se, numbers, name, identifier))
if not choices:
    raise SystemExit("Selected iOS runtime exposes no supported iPhone device type")
# Prefer a current non-SE iPhone from the runtime-owned compatibility list.
non_se = [item for item in choices if item[0] == 0]
selected = sorted(non_se or choices, key=lambda item: (item[1], item[2]))[-1]
print(selected[3])
print(selected[2])
'
}

capture_simulator_logs() {
  local label="$1"
  local window="${2:-10m}"
  if [[ -z "$CREATED_UDID" ]]; then
    return 0
  fi
  xcrun simctl spawn "$CREATED_UDID" log show \
    --last "$window" \
    --style compact \
    --predicate 'process == "Runner" OR subsystem BEGINSWITH "app.sonusauris" OR process == "SpringBoard"' \
    2>/dev/null \
    | python3 "$BOUNDED_LOG" --max-bytes 524288 \
    | python3 "$EVIDENCE_POLICY" --stream \
    > "$EVIDENCE_DIR/$label-simulator.log" || true
}

write_cleanup_evidence() {
  cat > "$EVIDENCE_DIR/cleanup.txt" <<CLEANUP
simulator_created_by_probe=true
simulator_deleted=$SIMULATOR_DELETED
existing_simulator_addressed=false
physical_iphone_addressed=false
CLEANUP
}

delete_created_simulator() {
  if [[ -z "$CREATED_UDID" ]]; then
    write_cleanup_evidence
    return 0
  fi
  xcrun simctl terminate "$CREATED_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$CREATED_UDID" >/dev/null 2>&1 || true
  if ! xcrun simctl delete "$CREATED_UDID" >/dev/null 2>&1; then
    echo "Could not delete the test-created iOS Simulator." >&2
    write_cleanup_evidence
    return 1
  fi
  if xcrun simctl list devices --json | SIM_UDID="$CREATED_UDID" python3 -c '
import json
import os
import sys
payload = json.load(sys.stdin)
needle = os.environ["SIM_UDID"]
for devices in payload.get("devices", {}).values():
    if any(device.get("udid") == needle for device in devices):
        raise SystemExit(0)
raise SystemExit(1)
' >/dev/null 2>&1; then
    echo "The test-created simulator still appears in simctl after deletion." >&2
    write_cleanup_evidence
    return 1
  fi
  SIMULATOR_DELETED=true
  CREATED_UDID=""
  write_cleanup_evidence
}

cleanup() {
  local status=$?
  if [[ -n "$DRIVE_PID" ]]; then
    kill "$DRIVE_PID" >/dev/null 2>&1 || true
    wait "$DRIVE_PID" >/dev/null 2>&1 || true
    DRIVE_PID=""
  fi
  if [[ "$status" != "0" && -n "$CREATED_UDID" ]]; then
    capture_simulator_logs failure 15m
  fi
  if [[ -n "$CREATED_UDID" ]]; then
    delete_created_simulator || status=1
  else
    write_cleanup_evidence
  fi
  return "$status"
}

verify_flutter_device_visibility() {
  flutter devices --machine | SIM_UDID="$CREATED_UDID" python3 -c '
import json
import os
import sys
payload = json.load(sys.stdin)
needle = os.environ["SIM_UDID"]
matching = [device for device in payload if device.get("id") == needle]
if len(matching) != 1:
    raise SystemExit("Flutter did not discover the test-created simulator exactly once")
device = matching[0]
if not device.get("emulator"):
    raise SystemExit("Flutter classified the test-created target as physical")
target = str(device.get("targetPlatform", "")).lower()
platform = str(device.get("platform", "")).lower()
if not (target.startswith("ios") or platform.startswith("ios")):
    raise SystemExit("Flutter did not classify the test-created target as iOS")
print("target_visible=true")
print("target_emulator=true")
print("target_platform=ios")
print("target_supported=" + str(bool(device.get("supported", True))).lower())
'
}

main() {
  # The outer evidence pipeline temporarily disables errexit to retain every
  # pipeline status. Restore fail-closed execution inside the probe.
  set -euo pipefail

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The disposable iOS permission lab must run on a Mac with Xcode." >&2
    exit 2
  fi
  need xcrun
  need flutter
  need python3
  need shasum
  [[ -f "$EVIDENCE_POLICY" && -f "$BOUNDED_LOG" ]] || {
    echo "Device-lab evidence helpers are missing." >&2
    exit 2
  }
  if [[ ! "$MAX_RUNTIME_MAJOR" =~ ^[0-9]+$ ]] || (( MAX_RUNTIME_MAJOR < 1 )); then
    echo "SONUS_IOS_PERMISSION_LAB_MAX_RUNTIME_MAJOR must be a positive integer." >&2
    exit 64
  fi
  if [[ -n "$REQUESTED_RUNTIME_MAJOR" && ! "$REQUESTED_RUNTIME_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "SONUS_IOS_PERMISSION_LAB_RUNTIME_MAJOR must be an integer when set." >&2
    exit 64
  fi
  if [[ ! "$DRIVE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( DRIVE_TIMEOUT_SECONDS < 60 )); then
    echo "SONUS_IOS_PERMISSION_DRIVE_TIMEOUT_SECONDS must be at least 60." >&2
    exit 64
  fi

  local runtime_selection
  local device_selection
  local runtime_id
  local runtime_name
  local runtime_major
  local runtime_version
  local runtime_policy
  local device_type_id
  local device_type_name
  runtime_selection="$(select_runtime)"
  runtime_id="$(printf '%s\n' "$runtime_selection" | sed -n '1p')"
  runtime_name="$(printf '%s\n' "$runtime_selection" | sed -n '2p')"
  runtime_major="$(printf '%s\n' "$runtime_selection" | sed -n '3p')"
  runtime_version="$(printf '%s\n' "$runtime_selection" | sed -n '4p')"
  runtime_policy="$(printf '%s\n' "$runtime_selection" | sed -n '5p')"
  device_selection="$(select_device_type "$runtime_id")"
  device_type_id="$(printf '%s\n' "$device_selection" | sed -n '1p')"
  device_type_name="$(printf '%s\n' "$device_selection" | sed -n '2p')"

  local simulator_name="Sonus Auris Permission Lab $STAMP $$"
  CREATED_UDID="$(xcrun simctl create "$simulator_name" "$device_type_id" "$runtime_id")"
  if [[ ! "$CREATED_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    echo "simctl did not return a valid UUID for the test-created simulator." >&2
    exit 3
  fi
  trap cleanup EXIT HUP INT TERM

  cat > "$EVIDENCE_DIR/device.txt" <<DEVICE
simulator_fingerprint=$(hash_text "$CREATED_UDID")
runtime=$runtime_name
runtime_major=$runtime_major
runtime_version=$runtime_version
runtime_selection_policy=$runtime_policy
runtime_compatibility_cap=$MAX_RUNTIME_MAJOR
device_type=$device_type_name
created_by_probe=true
existing_simulator_addressed=false
physical_iphone_addressed=false
DEVICE

  xcrun simctl boot "$CREATED_UDID"
  xcrun simctl bootstatus "$CREATED_UDID" -b
  verify_flutter_device_visibility > "$EVIDENCE_DIR/flutter-device.txt"

  echo "== build iOS permission-denial integration candidate =="
  (
    cd "$ROOT"
    flutter pub get
    flutter build ios --simulator --debug \
      --target="$TARGET" \
      --dart-define=SONUS_IOS_PERMISSION_DENIAL_LAB=true \
      --dart-define=SONUS_BACKEND_BASE_URL=https://ci.invalid \
      --dart-define=SONUS_SUPABASE_URL=https://ci.supabase.co \
      --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_ios_permission_lab
  )

  local app="$ROOT/build/ios/iphonesimulator/Runner.app"
  if [[ ! -d "$app" ]]; then
    app=""
    for candidate in "$ROOT"/build/ios/*iphonesimulator*/Runner.app; do
      if [[ -d "$candidate" ]]; then
        app="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "Flutter did not produce an iOS Simulator Runner.app." >&2
    exit 4
  fi

  local observed_bundle
  observed_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  if [[ "$observed_bundle" != "$BUNDLE_ID" ]]; then
    echo "Refusing app with unexpected bundle identifier '$observed_bundle'." >&2
    exit 4
  fi

  APP_ROOT="$app" python3 - <<'PY' > "$EVIDENCE_DIR/app-files.sha256"
import hashlib
import os
from pathlib import Path
root = Path(os.environ["APP_ROOT"])
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    print(f"{digest.hexdigest()}  {path.relative_to(root)}")
PY

  echo "== install only on the test-created simulator and revoke microphone =="
  xcrun simctl install "$CREATED_UDID" "$app"
  xcrun simctl privacy "$CREATED_UDID" revoke microphone "$BUNDLE_ID"
  local pre_drive_container
  pre_drive_container="$(xcrun simctl get_app_container "$CREATED_UDID" "$BUNDLE_ID" app)" || {
    echo "The permission-lab app was not installed before Flutter drive." >&2
    exit 4
  }
  printf 'pre_drive_app_container_fingerprint=%s\n' "$(hash_text "$pre_drive_container")" \
    > "$EVIDENCE_DIR/pre-drive-app.txt"
  cat > "$EVIDENCE_DIR/isolation.txt" <<ISOLATION
bundle_id=$BUNDLE_ID
disposable_simulator=true
existing_simulator_addressed=false
physical_iphone_addressed=false
microphone_privacy_revoked=true
ISOLATION

  local drive_log="$EVIDENCE_DIR/drive.log"
  (
    set -o pipefail
    (
      cd "$ROOT"
      flutter drive \
        --driver=test_driver/integration_test.dart \
        --target="$TARGET" \
        --use-application-binary="$app" \
        --dart-define=SONUS_IOS_PERMISSION_DENIAL_LAB=true \
        --keep-app-running \
        -d "$CREATED_UDID"
    ) 2>&1 | python3 "$EVIDENCE_POLICY" --stream | tee "$drive_log"
  ) &
  DRIVE_PID=$!

  local deadline=$((SECONDS + DRIVE_TIMEOUT_SECONDS))
  while kill -0 "$DRIVE_PID" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "iOS permission-denial flutter drive exceeded the ${DRIVE_TIMEOUT_SECONDS}-second deadline." >&2
      kill "$DRIVE_PID" >/dev/null 2>&1 || true
      wait "$DRIVE_PID" >/dev/null 2>&1 || true
      DRIVE_PID=""
      capture_simulator_logs drive-timeout 15m
      exit 5
    fi
    sleep 1
  done
  local drive_status=0
  wait "$DRIVE_PID" || drive_status=$?
  DRIVE_PID=""
  if [[ "$drive_status" != "0" ]]; then
    capture_simulator_logs drive-failure 15m
    echo "iOS permission-denial Flutter drive/evidence pipeline failed with status $drive_status." >&2
    exit "$drive_status"
  fi

  grep -Fq 'SONUS_IOS_PERMISSION_DENIAL_RESULT' "$drive_log"
  grep -Fq 'SONUS_IOS_PERMISSION_DENIAL_CLEANUP_PASSED' "$drive_log"

  local app_container
  app_container="$(xcrun simctl get_app_container "$CREATED_UDID" "$BUNDLE_ID" app)" || {
    echo "Flutter drive removed the permission-lab app unexpectedly." >&2
    exit 6
  }
  printf 'installed_app_container_fingerprint=%s\n' "$(hash_text "$app_container")" \
    > "$EVIDENCE_DIR/package-path.txt"

  capture_simulator_logs runtime 5m
  if grep -Eq 'Terminating app due to uncaught exception|Fatal error|EXC_CRASH|SIGABRT|Lost connection to device|Library not loaded|dyld.*Reason' \
    "$EVIDENCE_DIR/runtime-simulator.log"; then
    echo "Fatal iOS Simulator evidence was observed during permission denial." >&2
    exit 7
  fi

  xcrun simctl terminate "$CREATED_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  delete_created_simulator

  cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=disposable-ios-simulator-user-denied-microphone
bundle_id=$BUNDLE_ID
simulator_created_by_probe=true
simulator_deleted=$SIMULATOR_DELETED
existing_simulator_addressed=false
physical_iphone_addressed=false
runtime_major=$runtime_major
runtime_compatibility_cap=$MAX_RUNTIME_MAJOR
flutter_target_visible=true
microphone_privacy_revoked=true
permission_error_surfaced=true
recording_started=false
probe_audio_artifacts=0
raw_audio_exported=false
flutter_drive_keep_app_running=true
app_installation_verified_before_simulator_deletion=true
RESULT
  echo "IOS DISPOSABLE PERMISSION-DENIAL PROBE PASSED"
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
