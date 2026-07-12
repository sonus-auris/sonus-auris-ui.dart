#!/usr/bin/env bash
# Boot the headless AVD, wait for it, run the permission smoke-test, tear down.
set -euo pipefail

APK_PATH="${APK_PATH:-/work/app-release.apk}"
[[ -f "$APK_PATH" ]] || { echo "APK not found at APK_PATH=$APK_PATH (bind-mount it in)"; exit 2; }

if [[ ! -e /dev/kvm ]]; then
  echo "WARNING: /dev/kvm not present — the emulator will use software rendering"
  echo "and is likely too slow to boot. Run on a KVM-capable node (bare-metal /"
  echo "nested-virt: AWS *.metal, Hetzner dedicated) and expose /dev/kvm."
fi

adb start-server

echo "== booting headless emulator sonus_ci =="
emulator -avd sonus_ci \
  -no-window -no-audio -no-boot-anim -no-snapshot -accel auto \
  -gpu swiftshader_indirect -camera-back none -camera-front none \
  -read-only >/tmp/emulator.log 2>&1 &
EMU_PID=$!
trap 'adb emu kill >/dev/null 2>&1 || kill "$EMU_PID" 2>/dev/null || true' EXIT

echo "== waiting for boot (timeout 300s) =="
adb wait-for-device
for _ in $(seq 1 150); do
  [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
  sleep 2
done
[[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] \
  || { echo "emulator failed to boot; tail of log:"; tail -40 /tmp/emulator.log; exit 3; }

export SMOKE_SCREENSHOT="${SMOKE_SCREENSHOT:-/work/permission-smoke.png}"
permission-smoke.sh "$APK_PATH"
