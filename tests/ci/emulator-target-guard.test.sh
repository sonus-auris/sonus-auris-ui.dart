#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RESOLVER="$ROOT/scripts/emulator/resolve-emulator-serial.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"

cat > "$TMP/bin/adb" <<'ADB'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${FAKE_ADB_CALLS:?}"
printf '\n' >> "$FAKE_ADB_CALLS"
if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\n'
  cat "${FAKE_ADB_DEVICES:?}"
  exit 0
fi
if [[ "${1:-}" == "-s" ]]; then
  serial="${2:?}"
  shift 2
  case "${1:-}" in
    get-state)
      awk -v s="$serial" '$1 == s { print $2; found=1 } END { if (!found) exit 1 }' "$FAKE_ADB_DEVICES"
      ;;
    shell)
      shift
      if [[ "${1:-}" == "getprop" && "${2:-}" == "ro.kernel.qemu" ]]; then
        awk -v s="$serial" '$1 == s { print $2; found=1 } END { if (!found) exit 1 }' "$FAKE_ADB_QEMU"
      else
        exit 90
      fi
      ;;
    *) exit 91 ;;
  esac
  exit 0
fi
exit 92
ADB
chmod +x "$TMP/bin/adb"

export PATH="$TMP/bin:$PATH"
export FAKE_ADB_DEVICES="$TMP/devices"
export FAKE_ADB_QEMU="$TMP/qemu"
export FAKE_ADB_CALLS="$TMP/calls"

reset_fake() {
  : > "$FAKE_ADB_DEVICES"
  : > "$FAKE_ADB_QEMU"
  : > "$FAKE_ADB_CALLS"
}

expect_success() {
  local expected="$1"; shift
  local actual
  actual="$("$RESOLVER" "$@")"
  [[ "$actual" == "$expected" ]] || {
    echo "expected '$expected', got '$actual'" >&2
    exit 1
  }
}

expect_status() {
  local expected="$1"; shift
  set +e
  "$RESOLVER" "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  local status=$?
  set -e
  [[ "$status" == "$expected" ]] || {
    echo "expected status $expected, got $status" >&2
    cat "$TMP/stderr" >&2
    exit 1
  }
}

# 1. A sole physical device is never selected.
reset_fake
printf 'usb-phone\tdevice\n' > "$FAKE_ADB_DEVICES"
printf 'usb-phone\t0\n' > "$FAKE_ADB_QEMU"
expect_status 78

# 2. A normal local emulator is selected.
reset_fake
printf 'emulator-5554\tdevice\n' > "$FAKE_ADB_DEVICES"
printf 'emulator-5554\t1\n' > "$FAKE_ADB_QEMU"
expect_success emulator-5554

# 3. A mixed physical+emulator set selects only the emulator.
reset_fake
printf 'usb-phone\tdevice\nemulator-5556\tdevice\n' > "$FAKE_ADB_DEVICES"
printf 'usb-phone\t0\nemulator-5556\t1\n' > "$FAKE_ADB_QEMU"
expect_success emulator-5556

# 4. Two emulators are ambiguous and fail closed.
reset_fake
printf 'emulator-5554\tdevice\n127.0.0.1:5555\tdevice\n' > "$FAKE_ADB_DEVICES"
printf 'emulator-5554\t1\n127.0.0.1:5555\t1\n' > "$FAKE_ADB_QEMU"
expect_status 64

# 5. An explicitly requested physical serial is refused.
reset_fake
printf 'usb-phone\tdevice\n' > "$FAKE_ADB_DEVICES"
printf 'usb-phone\t0\n' > "$FAKE_ADB_QEMU"
expect_status 64 usb-phone

# 6. A remote emulator serial is accepted based on ro.kernel.qemu, not naming.
reset_fake
printf '10.0.0.8:5555\tdevice\n' > "$FAKE_ADB_DEVICES"
printf '10.0.0.8:5555\t1\n' > "$FAKE_ADB_QEMU"
expect_success 10.0.0.8:5555 10.0.0.8:5555

# The resolver may only enumerate, read state, and read ro.kernel.qemu.
if grep -Eq '(^| )(uninstall|install|pm|am|logcat|shell input|shell rm)( |$)' "$FAKE_ADB_CALLS"; then
  echo "target resolver issued a destructive or mutating adb command" >&2
  cat "$FAKE_ADB_CALLS" >&2
  exit 1
fi

echo "emulator target guard tests passed: 6 cases"
