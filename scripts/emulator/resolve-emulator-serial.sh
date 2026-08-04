#!/usr/bin/env bash
# Resolve exactly one authorized Android emulator and refuse physical targets.
# Prints only the selected adb serial on stdout. Diagnostics go to stderr.
set -euo pipefail

REQUESTED_SERIAL="${1:-${ANDROID_EMULATOR_SERIAL:-}}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}
need adb

is_emulator() {
  local serial="$1"
  local state qemu
  state="$(adb -s "$serial" get-state 2>/dev/null | tr -d '\r' || true)"
  [[ "$state" == "device" ]] || return 1
  qemu="$(adb -s "$serial" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
  [[ "$qemu" == "1" ]]
}

if [[ -n "$REQUESTED_SERIAL" ]]; then
  if ! is_emulator "$REQUESTED_SERIAL"; then
    echo "Refusing Android target '$REQUESTED_SERIAL': it is not an authorized emulator (ro.kernel.qemu != 1)." >&2
    exit 64
  fi
  printf '%s\n' "$REQUESTED_SERIAL"
  exit 0
fi

AUTHORIZED="$(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }')"
EMULATORS=""
for serial in $AUTHORIZED; do
  if is_emulator "$serial"; then
    EMULATORS="${EMULATORS}${EMULATORS:+$'\n'}${serial}"
  fi
done

COUNT="$(printf '%s\n' "$EMULATORS" | awk 'NF { count++ } END { print count + 0 }')"
case "$COUNT" in
  1)
    printf '%s\n' "$EMULATORS"
    ;;
  0)
    echo "No authorized Android emulator is attached. Physical devices are intentionally excluded." >&2
    exit 78
    ;;
  *)
    echo "Multiple Android emulators are attached; pass an exact serial explicitly." >&2
    printf '%s\n' "$EMULATORS" | sed 's/^/  - /' >&2
    exit 64
    ;;
esac
