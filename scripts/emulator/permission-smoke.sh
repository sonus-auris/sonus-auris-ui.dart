#!/usr/bin/env bash
# Headless permission smoke-test for Sonus Auris on an Android emulator.
#
# Installs the app, launches it, exercises every runtime permission the way a
# store reviewer would (grant the mic/notification path; confirm the sensitive
# context permissions — location / Bluetooth / nearby-Wi-Fi — default to DENIED,
# i.e. opt-in), and fails if the app crashes. Runs identically:
#   - locally against a booted emulator,
#   - inside ci/android-emulator/Dockerfile,
#   - in GitHub Actions (reactivecircus/android-emulator-runner).
#
# Usage: permission-smoke.sh <apk-path> [adb-serial]
#   apk-path   : built debug/release APK to install
#   adb-serial : emulator serial (default: first attached device)
set -euo pipefail

APK="${1:?usage: permission-smoke.sh <apk-path> [adb-serial]}"
SERIAL="${2:-}"
PKG="com.ores.audio_dashcam"
ACTIVITY="$PKG/.MainActivity"

adb_() { if [[ -n "$SERIAL" ]]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

echo "== waiting for device + full boot =="
adb_ wait-for-device
# Block until the framework reports boot complete.
until [[ "$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 2
done
adb_ shell input keyevent 82 >/dev/null 2>&1 || true   # dismiss keyguard

echo "== installing $APK (clean install; do NOT pre-grant, so the opt-in default is real) =="
adb_ uninstall "$PKG" >/dev/null 2>&1 || true   # clean slate: clear any persisted grants
adb_ install -r "$APK"   # no -g: dangerous runtime perms must start DENIED (opt-in)

echo "== requested permissions (must match AndroidManifest) =="
adb_ shell dumpsys package "$PKG" | awk '
  /requested permissions:/ { show=1 }
  show { print }
  /install permissions:/ { exit }
'

echo "== launch =="
adb_ logcat -c
adb_ shell am start -W -n "$ACTIVITY" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER

# Give the Flutter engine time to draw the first frame.
sleep 8

dump_ui() {
  adb_ shell uiautomator dump /sdcard/sonus-window.xml >/dev/null
  adb_ exec-out cat /sdcard/sonus-window.xml | tr -d '\r'
}

assert_ui_text() {
  local label="$1"
  local xml="$2"
  # Flutter may expose a visible Text widget either as the node's `text` or
  # inside a merged `content-desc` semantics label. The UI hierarchy contains
  # visible nodes only, so matching the label in either representation is the
  # reliable cross-emulator assertion.
  if grep -Fq "$label" <<< "$xml"; then
    echo "  ✓ visible: $label"
  else
    echo "  ✗ missing UI text: $label"
    return 1
  fi
}

tap_ui_text() {
  local label="$1"
  local xml="$2"
  local center
  center="$(LABEL="$label" python3 -c '
import os
import re
import sys
import xml.etree.ElementTree as ET

root = ET.fromstring(sys.stdin.read())
label = os.environ["LABEL"]
node = next(
    (
        item
        for item in root.iter("node")
        if item.attrib.get("text") == label
        or item.attrib.get("content-desc") == label
    ),
    None,
)
if node is None:
    raise SystemExit(1)
points = [int(value) for value in re.findall(r"\d+", node.attrib["bounds"])]
print((points[0] + points[2]) // 2, (points[1] + points[3]) // 2)
' <<< "$xml")"
  read -r x y <<< "$center"
  adb_ shell input tap "$x" "$y"
}

wait_for_ui_text() {
  local label="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    ui_xml="$(dump_ui 2>/dev/null || true)"
    if grep -Fq "$label" <<< "$ui_xml"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

capture_failure_evidence() {
  if [[ -n "${SMOKE_SCREENSHOT:-}" ]]; then
    adb_ exec-out screencap -p > "$SMOKE_SCREENSHOT" 2>/dev/null || true
  fi
  echo "  visible hierarchy:"
  printf '%s\n' "$ui_xml"
  echo "  recent app logcat:"
  adb_ logcat -d 2>/dev/null | awk -v package="$PKG" '
    index($0, package) || /AndroidRuntime/ || /flutter/ { lines[++count]=$0 }
    END {
      start = count > 80 ? count - 79 : 1
      for (i = start; i <= count; i++) print lines[i]
    }
  '
}

echo "== account UI smoke-test =="
ui_xml=""
if ! wait_for_ui_text "Welcome to Sonus Auris" 40; then
  echo "  ✗ welcome screen did not become ready within 40 seconds"
  capture_failure_evidence
  exit 1
fi
assert_ui_text "Welcome to Sonus Auris" "$ui_xml"
assert_ui_text "Continue" "$ui_xml"
tap_ui_text "Continue" "$ui_xml"
if ! wait_for_ui_text "Create your Sonus Auris account" 20; then
  echo "  ✗ account screen did not become ready within 20 seconds"
  capture_failure_evidence
  exit 1
fi
assert_ui_text "Create your Sonus Auris account" "$ui_xml"
assert_ui_text "Sign in" "$ui_xml"
assert_ui_text "Create account" "$ui_xml"

echo "== runtime permission model (sensitive context perms must default to DENIED / opt-in) =="
fail=0
check_denied() {
  local perm="$1"
  local line
  line="$(adb_ shell dumpsys package "$PKG" | awk -v permission="android.permission.$perm:" '
    index($0, permission) { print; exit }
  ' | tr -d '\r')"
  if echo "$line" | grep -q "granted=true"; then
    echo "  ✗ $perm is granted by default (expected opt-in / denied): $line"
    fail=1
  else
    echo "  ✓ $perm defaults to denied (opt-in)"
  fi
}
# These are all OFF-by-default context triggers per the privacy design.
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION BLUETOOTH_SCAN BLUETOOTH_CONNECT NEARBY_WIFI_DEVICES; do
  check_denied "$p"
done

echo "== reviewer 'allow' path: grant each runtime permission, app must not crash =="
for p in RECORD_AUDIO POST_NOTIFICATIONS ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION \
         BLUETOOTH_SCAN BLUETOOTH_CONNECT NEARBY_WIFI_DEVICES; do
  adb_ shell pm grant "$PKG" "android.permission.$p" 2>/dev/null && echo "  granted $p" || echo "  (skip $p)"
done
sleep 3

echo "== crash check =="
if adb_ logcat -d 2>/dev/null | grep -m1 -E "FATAL EXCEPTION|E AndroidRuntime.*$PKG"; then
  echo "  ✗ app crashed after permission grants"
  fail=1
else
  echo "  ✓ no FATAL / AndroidRuntime crash in logcat"
fi

echo "== process alive? =="
if [[ -n "$(adb_ shell pidof "$PKG" | tr -d '\r')" ]]; then
  echo "  ✓ app process is running"
else
  echo "  ✗ app process is not running after launch"
  fail=1
fi

# Best-effort evidence screenshot (ignored if the harness has nowhere to put it).
if [[ -n "${SMOKE_SCREENSHOT:-}" ]]; then
  adb_ exec-out screencap -p > "$SMOKE_SCREENSHOT" 2>/dev/null && echo "  screenshot -> $SMOKE_SCREENSHOT"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "PERMISSION SMOKE TEST FAILED"; exit 1
fi
echo "PERMISSION SMOKE TEST PASSED"
