#!/usr/bin/env bash
# Package and exercise the Flutter macOS app as an app bundle, verifying that
# launch and explicit Quit are owned by Sonus Auris rather than Terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUNDLE_ID="app.sonusauris.audioDashcam"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/flutter-macos-$STAMP}"
CAPTURE_SCREENSHOT="${SONUS_CAPTURE_SCREENSHOT:-0}"
REQUIRE_APPLE_EVENT_QUIT="${SONUS_REQUIRE_APPLE_EVENT_QUIT:-1}"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee "$EVIDENCE_DIR/run.log") 2>&1

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 2
  }
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Flutter macOS runtime smoke must run on macOS." >&2
  exit 2
fi

need flutter
need open
need osascript
need codesign
need python3

BACKEND_URL="${SONUS_BACKEND_BASE_URL:-http://127.0.0.1:8126}"
SUPABASE_URL="${SONUS_SUPABASE_URL:-http://127.0.0.1:54321}"
SUPABASE_KEY="${SONUS_SUPABASE_ANON_KEY:-sb_publishable_compile_only}"

(
  cd "$ROOT"
  flutter pub get
  flutter build macos --release -t lib/main_desktop.dart \
    --dart-define="SONUS_BACKEND_BASE_URL=$BACKEND_URL" \
    --dart-define="SONUS_SUPABASE_URL=$SUPABASE_URL" \
    --dart-define="SONUS_SUPABASE_ANON_KEY=$SUPABASE_KEY"
)

APP=""
for candidate in "$ROOT"/build/macos/Build/Products/Release/*.app; do
  if [[ -d "$candidate" ]]; then
    APP="$candidate"
    break
  fi
done
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Flutter did not produce a packaged macOS .app" >&2
  exit 3
fi

INFO_PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Unexpected Flutter macOS bundle identifier: $ACTUAL_BUNDLE_ID" >&2
  exit 4
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tee "$EVIDENCE_DIR/codesign.txt"
{
  echo "bundle_id=$ACTUAL_BUNDLE_ID"
  echo "executable=$EXECUTABLE"
  echo "app_name=$(basename "$APP")"
  echo "configuration_mode=$([[ "$BACKEND_URL" == http://127.0.0.1:* ]] && echo compile-only || echo configured)"
} > "$EVIDENCE_DIR/bundle.txt"

sanitize_stream() {
  python3 -c '
import re
import sys
text = sys.stdin.read()
patterns = [
    (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", "<redacted-jwt>"),
    (r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization_code|otp)=([^&\s]+)", r"\1=<redacted>"),
]
for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text)
sys.stdout.write(text)
'
}

process_id_for_app() {
  ps -axo pid=,command= | awk -v needle="$APP/Contents/MacOS/$EXECUTABLE" 'index($0, needle) { print $1; exit }'
}

wait_for_process() {
  expected="$1"
  limit="$2"
  deadline=$((SECONDS + limit))
  while (( SECONDS < deadline )); do
    pid="$(process_id_for_app)"
    if [[ "$expected" == "present" && -n "$pid" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    if [[ "$expected" == "absent" && -z "$pid" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Terminate a stale instance through the normal app event before launching the
# candidate. This does not touch recordings, preferences, keys, or app data.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
wait_for_process absent 15 || {
  stale_pid="$(process_id_for_app)"
  if [[ -n "$stale_pid" ]]; then
    kill "$stale_pid" >/dev/null 2>&1 || true
  fi
}

open -n "$APP"
if ! pid="$(wait_for_process present 30)"; then
  echo "Packaged Flutter macOS process did not remain alive after launch." >&2
  exit 5
fi
printf 'pid=%s\n' "$pid" > "$EVIDENCE_DIR/launch-process.txt"
sleep 6

if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  screencapture -x "$EVIDENCE_DIR/launch.png" >/dev/null 2>&1 || true
fi

log show --last 3m --style compact \
  --predicate "process == \"$EXECUTABLE\"" 2>/dev/null \
  | tail -n 500 \
  | sanitize_stream > "$EVIDENCE_DIR/app.log" || true

if grep -Eq 'Fatal error|abort\(\)|EXC_CRASH|SIGABRT|segmentation fault' "$EVIDENCE_DIR/app.log"; then
  echo "Fatal packaged Flutter macOS evidence was found." >&2
  kill "$pid" >/dev/null 2>&1 || true
  exit 6
fi

echo "== explicit app-bundle Quit =="
if osascript -e "tell application id \"$BUNDLE_ID\" to quit" > "$EVIDENCE_DIR/quit-event.txt" 2>&1; then
  quit_event_sent=true
else
  quit_event_sent=false
fi

if ! wait_for_process absent 20; then
  remaining_pid="$(process_id_for_app)"
  if [[ -n "$remaining_pid" ]]; then
    kill "$remaining_pid" >/dev/null 2>&1 || true
  fi
  echo "Packaged Flutter macOS app did not terminate within the bounded Quit window." >&2
  exit 7
fi

if [[ "$REQUIRE_APPLE_EVENT_QUIT" == "1" && "$quit_event_sent" != "true" ]]; then
  echo "Apple-event Quit could not be sent. Grant Terminal/runner Automation permission and rerun." >&2
  exit 8
fi

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=packaged-flutter-macos-launch-explicit-quit
bundle_id=$BUNDLE_ID
quit_event_sent=$quit_event_sent
quit_bounded=true
app_data_cleared=false
screenshot_captured=$CAPTURE_SCREENSHOT
RESULT

echo "FLUTTER MACOS PACKAGED RUNTIME SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
