#!/usr/bin/env bash
# Non-destructive launch/lifecycle smoke for an attached Android device.
#
# Unlike scripts/emulator/permission-smoke.sh, this physical-device harness
# never uninstalls the package, clears app data, changes runtime permissions, or
# clears the device-wide logcat buffer. It may update/install the supplied APK,
# background/foreground the app, force-stop the Sonus Auris process, and relaunch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PKG="com.ores.sonus_auris"
ACTIVITY="$PKG/.MainActivity"
APK="${1:-$ROOT/build/app/outputs/flutter-apk/app-debug.apk}"
SERIAL="${2:-${ANDROID_SERIAL:-}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/android-$STAMP}"
CAPTURE_SCREENSHOT="${SONUS_CAPTURE_SCREENSHOT:-0}"
REQUIRE_UI="${SONUS_REQUIRE_ANDROID_UI:-0}"
ALLOW_EMULATOR="${SONUS_ALLOW_ANDROID_EMULATOR:-0}"
REQUIRE_PACKAGE_STATE_PRESERVATION="${SONUS_REQUIRE_PACKAGE_STATE_PRESERVATION:-1}"
LOGCAT_SINCE_EPOCH="0"
mkdir -p "$EVIDENCE_DIR"

# Sanitize the complete run log, including Flutter/ADB failures that may contain
# a local account path, an auth callback, or token-shaped material.
exec > >(python3 -u -c '
import re
import sys
patterns = [
    (re.compile(r"/Users/[^/\s]+"), "/Users/<redacted>"),
    (re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)(access_token|refresh_token|id_token|token|code|code_verifier|authorization_code|otp)=([^&\s]+)"), r"\1=<redacted>"),
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "<redacted-email>"),
]
for line in sys.stdin:
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    sys.stdout.write(line)
    sys.stdout.flush()
' | tee "$EVIDENCE_DIR/run.log") 2>&1

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

need adb
need python3
need shasum

attached_devices() {
  adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1 }'
}

if [[ -z "$SERIAL" ]]; then
  device_list="$(attached_devices)"
  device_count="$(printf '%s\n' "$device_list" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "$device_count" == "0" ]]; then
    echo "No authorized physical Android device is visible. Unlock the handset, enable USB debugging, and accept the RSA prompt." >&2
    exit 3
  fi
  if [[ "$device_count" != "1" ]]; then
    echo "More than one authorized physical Android target is attached. Pass the intended adb serial as argument 2 or set ANDROID_SERIAL." >&2
    exit 3
  fi
  SERIAL="$device_list"
fi

serial_state="$(adb devices | awk -v serial="$SERIAL" '$1 == serial { print $2; exit }')"
if [[ -z "$serial_state" ]]; then
  echo "The requested Android serial is not visible to adb." >&2
  exit 3
fi
if [[ "$serial_state" != "device" ]]; then
  echo "Android target $SERIAL is $serial_state. Unlock it and approve USB debugging before rerunning." >&2
  exit 3
fi

if [[ "$SERIAL" == emulator-* && "$ALLOW_EMULATOR" != "1" ]]; then
  echo "This harness preserves physical-device state and refuses emulator serials by default. Use scripts/emulator/permission-smoke.sh for the destructive emulator matrix." >&2
  exit 3
fi

adb_() {
  adb -s "$SERIAL" "$@"
}

if [[ "$(adb_ shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')" == "1" && "$ALLOW_EMULATOR" != "1" ]]; then
  echo "The selected adb target reports an emulator runtime. Use the emulator-only permission harness instead." >&2
  exit 3
fi

sanitize_stream() {
  python3 -c '
import re
import sys
text = sys.stdin.read()
patterns = [
    (r"/Users/[^/\s]+", "/Users/<redacted>"),
    (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", "<redacted-jwt>"),
    (r"(?i)(access_token|refresh_token|id_token|token|code|code_verifier|authorization_code|otp)=([^&\s]+)", r"\1=<redacted>"),
    (r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "<redacted-email>"),
    (r"http://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+", "http://127.0.0.1:<port>/<redacted>"),
]
for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text)
sys.stdout.write(text)
'
}

mark_logcat_start() {
  local candidate
  candidate="$(adb_ shell date +%s 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  if [[ ! "$candidate" =~ ^[0-9]+$ ]]; then
    candidate="$(date +%s)"
  fi
  LOGCAT_SINCE_EPOCH="$candidate"
}

recent_logcat() {
  # `-v epoch` gives a numeric timestamp in the first field. Filtering from a
  # device-derived epoch avoids stale crashes without destroying the shared
  # device log buffer via `logcat -c`.
  adb_ logcat -d -v epoch 2>/dev/null \
    | awk -v since="$LOGCAT_SINCE_EPOCH" '$1 ~ /^[0-9]+([.][0-9]+)?$/ && ($1 + 0) >= (since + 0)'
}

capture_package_state() {
  adb_ shell dumpsys package "$PKG" 2>/dev/null | tr -d '\r' | python3 -c '
import json
import re
import sys
first_install_time = None
permissions = {}
for line in sys.stdin:
    stripped = line.strip()
    if stripped.startswith("firstInstallTime="):
        first_install_time = stripped.split("=", 1)[1]
    match = re.match(r"(android\.permission\.[A-Z0-9_]+): granted=(true|false)", stripped)
    if match:
        permissions[match.group(1)] = match.group(2) == "true"
json.dump(
    {"first_install_time": first_install_time, "permissions": permissions},
    sys.stdout,
    sort_keys=True,
    indent=2,
)
print()
'
}

serial_fingerprint="$(printf '%s' "$SERIAL" | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
printf 'target_fingerprint=%s\n' "$serial_fingerprint" > "$EVIDENCE_DIR/target.txt"
{
  echo "manufacturer=$(adb_ shell getprop ro.product.manufacturer | tr -d '\r')"
  echo "model=$(adb_ shell getprop ro.product.model | tr -d '\r')"
  echo "android_release=$(adb_ shell getprop ro.build.version.release | tr -d '\r')"
  echo "sdk=$(adb_ shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "security_patch=$(adb_ shell getprop ro.build.version.security_patch | tr -d '\r')"
  echo "transport=authorized-adb"
} > "$EVIDENCE_DIR/device.txt"

if [[ ! -s "$APK" ]]; then
  need flutter
  echo "APK not found at $APK; building a local debug candidate without production secrets."
  (
    cd "$ROOT"
    flutter pub get
    flutter build apk --debug \
      --dart-define=SONUS_BACKEND_BASE_URL=https://ci.invalid \
      --dart-define=SONUS_SUPABASE_URL=https://ci.supabase.co \
      --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_device_lab
  )
fi

if [[ ! -s "$APK" ]]; then
  echo "APK build did not produce $APK" >&2
  exit 4
fi

apk_digest="$(shasum -a 256 "$APK" | awk '{print $1}')"
printf '%s  %s\n' "$apk_digest" "$(basename "$APK")" > "$EVIDENCE_DIR/apk.sha256"

existing_package=false
package_state_preserved=not-applicable
if adb_ shell pm path "$PKG" >/dev/null 2>&1; then
  existing_package=true
  capture_package_state > "$EVIDENCE_DIR/package-state-before.json"
fi

echo "== non-destructive install/update =="
echo "Existing package: $existing_package"
install_log="$EVIDENCE_DIR/install.txt"
if ! adb_ install -r "$APK" 2>&1 | sanitize_stream | tee "$install_log"; then
  cat <<'NOTICE' >&2
The update/install failed. A signing-certificate mismatch is common when a
release or Play build is already installed and this is a debug APK. This script
will not uninstall the existing app because uninstalling deletes app-private
audio, keys, settings, and account state. Supply an APK signed with the matching
certificate, or back up/export intentionally retained data before performing an
explicit uninstall outside this harness.
NOTICE
  exit 5
fi

capture_package_state > "$EVIDENCE_DIR/package-state-after.json"
if [[ "$existing_package" == "true" ]]; then
  if python3 - \
    "$EVIDENCE_DIR/package-state-before.json" \
    "$EVIDENCE_DIR/package-state-after.json" \
    "$EVIDENCE_DIR/package-preservation.txt" <<'PY'
import json
import sys
from pathlib import Path

before = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
after = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
problems = []
first_before = before.get("first_install_time")
first_after = after.get("first_install_time")
if first_before and first_after and first_before != first_after:
    problems.append("first_install_time_changed")
permission_changes = []
for permission, granted_before in before.get("permissions", {}).items():
    if permission in after.get("permissions", {}) and after["permissions"][permission] != granted_before:
        permission_changes.append(permission)
if permission_changes:
    problems.append("existing_permission_grant_changed")
Path(sys.argv[3]).write_text(
    "status=" + ("failed" if problems else "passed") + "\n"
    "existing_package=true\n"
    "first_install_time_preserved=" + str("first_install_time_changed" not in problems).lower() + "\n"
    "existing_permission_grants_preserved=" + str(not permission_changes).lower() + "\n"
    "problems=" + (",".join(problems) if problems else "none") + "\n",
    encoding="utf-8",
)
raise SystemExit(1 if problems else 0)
PY
  then
    package_state_preserved=true
  else
    package_state_preserved=false
    if [[ "$REQUIRE_PACKAGE_STATE_PRESERVATION" == "1" ]]; then
      echo "The in-place Android update changed pre-existing package state; inspect package-preservation.txt." >&2
      exit 12
    fi
  fi
else
  cat > "$EVIDENCE_DIR/package-preservation.txt" <<STATE
status=passed
existing_package=false
first_install_time_preserved=not-applicable
existing_permission_grants_preserved=not-applicable
problems=none
STATE
fi

echo "== launch =="
mark_logcat_start
launch_output="$(adb_ shell am start -W -n "$ACTIVITY" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>&1 || true)"
printf '%s\n' "$launch_output" | sanitize_stream | tee "$EVIDENCE_DIR/first-launch.txt"

wait_for_process() {
  limit="$1"
  deadline=$((SECONDS + limit))
  while (( SECONDS < deadline )); do
    if [[ -n "$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

collect_ui_summary() {
  ui_dump="$(adb_ shell uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' || true)"
  printf '%s' "$ui_dump" | python3 -c '
import sys
import xml.etree.ElementTree as ET
raw = sys.stdin.read()
start = raw.find("<?xml")
end = raw.rfind("</hierarchy>")
if start < 0 or end < 0:
    print("ui_dump=unavailable")
    raise SystemExit(0)
xml = raw[start:end + len("</hierarchy>")]
labels = []
try:
    root = ET.fromstring(xml)
except Exception:
    print("ui_dump=unavailable")
    raise SystemExit(0)
allowed = {
    "Sonus Auris",
    "Welcome to Sonus Auris",
    "Create your account",
    "Email me a 6-digit code",
    "Settings",
    "Recording",
    "Home",
}
for node in root.iter("node"):
    for key in ("text", "content-desc"):
        value = node.attrib.get(key, "").strip()
        if value in allowed:
            labels.append(value)
print("ui_labels=" + ", ".join(sorted(set(labels))) if labels else "ui_labels=<none-observed>")
'
}

capture_crash_evidence() {
  local phase="${1:?evidence phase is required}"
  recent_logcat \
    | grep -E "FATAL EXCEPTION|AndroidRuntime|Process $PKG|am_crash|flutter" \
    | tail -n 200 \
    | sanitize_stream > "$EVIDENCE_DIR/$phase-crash-focused-logcat.txt" || true
  adb_ shell dumpsys package "$PKG" 2>/dev/null \
    | awk '
      /versionCode=|versionName=|targetSdk=|android.permission.RECORD_AUDIO:|android.permission.POST_NOTIFICATIONS:|android.permission.ACCESS_FINE_LOCATION:|android.permission.BLUETOOTH_SCAN:|android.permission.NEARBY_WIFI_DEVICES:/ { print }
    ' > "$EVIDENCE_DIR/$phase-package-summary.txt" || true
  adb_ shell dumpsys activity activities 2>/dev/null \
    | grep -E "mResumedActivity|topResumedActivity|$PKG" \
    | head -n 80 \
    | sanitize_stream > "$EVIDENCE_DIR/$phase-activity-summary.txt" || true
  if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
    adb_ exec-out screencap -p > "$EVIDENCE_DIR/$phase-screenshot.png" 2>/dev/null || true
  fi
}

fatal_crash_in_phase() {
  local phase="${1:?evidence phase is required}"
  local package_regex="${PKG//./\\.}"
  grep -Eq \
    "Process:[[:space:]]*$package_regex([,[:space:]]|$)|am_crash.*$package_regex|Process[[:space:]]+$package_regex([[:space:]]+\([^)]*\))?[[:space:]]+has died" \
    "$EVIDENCE_DIR/$phase-crash-focused-logcat.txt"
}

if ! wait_for_process 40; then
  echo "App process did not remain alive after launch." >&2
  collect_ui_summary | tee "$EVIDENCE_DIR/ui-summary.txt" || true
  capture_crash_evidence first-launch-failure
  exit 6
fi
sleep 5
collect_ui_summary | tee "$EVIDENCE_DIR/ui-summary.txt"
if [[ "$REQUIRE_UI" == "1" ]] && grep -q '<none-observed>\|unavailable' "$EVIDENCE_DIR/ui-summary.txt"; then
  echo "No expected non-sensitive Sonus Auris label was exposed through Android accessibility semantics." >&2
  capture_crash_evidence first-launch-ui-failure
  exit 7
fi

capture_crash_evidence first-launch
if fatal_crash_in_phase first-launch; then
  echo "Fatal Android crash evidence was found after first launch." >&2
  exit 8
fi

echo "== Home/background + foreground resume =="
adb_ shell input keyevent KEYCODE_HOME
sleep 3
if [[ -n "$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]]; then
  process_survived_home=true
else
  process_survived_home=false
fi
mark_logcat_start
resume_output="$(adb_ shell am start -W -n "$ACTIVITY" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>&1 || true)"
printf '%s\n' "$resume_output" | sanitize_stream | tee "$EVIDENCE_DIR/home-resume.txt"
if ! wait_for_process 40; then
  echo "App process did not recover after Home/background resume." >&2
  capture_crash_evidence home-resume-failure
  exit 9
fi
sleep 4
capture_crash_evidence home-resume
if fatal_crash_in_phase home-resume; then
  echo "Fatal Android crash evidence was found after foreground resume." >&2
  exit 10
fi

echo "== safe force-stop + cold relaunch =="
adb_ shell am force-stop "$PKG"
sleep 1
if [[ -n "$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]]; then
  echo "force-stop did not terminate the process" >&2
  exit 11
fi
mark_logcat_start
relaunch_output="$(adb_ shell am start -W -n "$ACTIVITY" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>&1 || true)"
printf '%s\n' "$relaunch_output" | sanitize_stream | tee "$EVIDENCE_DIR/cold-relaunch.txt"
if ! wait_for_process 40; then
  echo "App process did not recover after cold relaunch." >&2
  capture_crash_evidence cold-relaunch-failure
  exit 13
fi
sleep 4
capture_crash_evidence cold-relaunch
if fatal_crash_in_phase cold-relaunch; then
  echo "Fatal Android crash evidence was found after cold relaunch." >&2
  exit 14
fi

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=non-destructive-install-launch-home-resume-cold-relaunch
package=$PKG
existing_package=$existing_package
package_state_preserved=$package_state_preserved
app_data_cleared=false
permissions_mutated=false
log_buffer_cleared=false
home_resume_completed=true
process_survived_home=$process_survived_home
screenshot_captured=$CAPTURE_SCREENSHOT
RESULT

echo "ANDROID ATTACHED-DEVICE SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
