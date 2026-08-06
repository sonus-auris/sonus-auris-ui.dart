#!/usr/bin/env bash
# Package and exercise the Flutter macOS app as an isolated app bundle,
# verifying that launch and explicit Quit are owned by Sonus Auris rather than
# Terminal without touching production preferences, login items, or recording.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PRODUCTION_BUNDLE_ID="app.sonusauris.audioDashcam"
RUNTIME_BUNDLE_ID="${PRODUCTION_BUNDLE_ID}.deviceLab"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
EVIDENCE_DIR="${SONUS_DEVICE_LAB_DIR:-$ROOT/build/device-lab/flutter-macos-$STAMP}"
PACKAGE_ROOT="$ROOT/build/device-lab-runtime/flutter-macos-$STAMP"
APP="$PACKAGE_ROOT/Sonus Auris Device Lab.app"
CAPTURE_SCREENSHOT="${SONUS_CAPTURE_SCREENSHOT:-0}"
REQUIRE_APPLE_EVENT_QUIT="${SONUS_REQUIRE_APPLE_EVENT_QUIT:-1}"

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

for command in flutter open osascript codesign python3 ditto; do
  need "$command"
done

mkdir -p "$EVIDENCE_DIR" "$PACKAGE_ROOT"
# Build tools can print the local account path. Sanitize the complete evidence
# log, not only the final app log.
exec > >(python3 -u -c '
import re
import sys
patterns = [
    (re.compile(r"/Users/[^/\s]+"), "/Users/<redacted>"),
    (re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer <redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"), "<redacted-jwt>"),
    (re.compile(r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization_code|otp)=([^&\s]+)"), r"\1=<redacted>"),
]
for line in sys.stdin:
    for pattern, replacement in patterns:
        line = pattern.sub(replacement, line)
    sys.stdout.write(line)
    sys.stdout.flush()
' | tee "$EVIDENCE_DIR/run.log") 2>&1

BACKEND_URL="${SONUS_BACKEND_BASE_URL:-http://127.0.0.1:8126}"
SUPABASE_URL="${SONUS_SUPABASE_URL:-http://127.0.0.1:54321}"
SUPABASE_KEY="${SONUS_SUPABASE_ANON_KEY:-sb_publishable_compile_only}"

(
  cd "$ROOT"
  flutter pub get
  flutter build macos --release -t lib/main_desktop.dart \
    --dart-define="SONUS_BACKEND_BASE_URL=$BACKEND_URL" \
    --dart-define="SONUS_SUPABASE_URL=$SUPABASE_URL" \
    --dart-define="SONUS_SUPABASE_ANON_KEY=$SUPABASE_KEY" \
    --dart-define=SONUS_DEVICE_LAB_NO_SIDE_EFFECTS=true
)

BUILT_APP=""
for candidate in "$ROOT"/build/macos/Build/Products/Release/*.app; do
  if [[ -d "$candidate" ]]; then
    BUILT_APP="$candidate"
    break
  fi
done
if [[ -z "$BUILT_APP" || ! -d "$BUILT_APP" ]]; then
  echo "Flutter did not produce a packaged macOS .app" >&2
  exit 3
fi

BUILT_INFO_PLIST="$BUILT_APP/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BUILT_INFO_PLIST")"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_INFO_PLIST")"
if [[ "$ACTUAL_BUNDLE_ID" != "$PRODUCTION_BUNDLE_ID" ]]; then
  echo "Unexpected Flutter macOS bundle identifier: $ACTUAL_BUNDLE_ID" >&2
  exit 4
fi

# Verify the real build identity first, then run a copied bundle under a unique
# device-lab identity. SharedPreferences/TCC/Keychain preference lookup therefore
# cannot inherit the production app's stored recording consent or account state.
codesign --verify --deep --strict --verbose=2 "$BUILT_APP" 2>&1 \
  | tee "$EVIDENCE_DIR/production-codesign.txt"
ditto "$BUILT_APP" "$APP"
INFO_PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RUNTIME_BUNDLE_ID" "$INFO_PLIST"
if ! /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Sonus Auris Device Lab' "$INFO_PLIST"; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Sonus Auris Device Lab' "$INFO_PLIST"
fi
if ! /usr/libexec/PlistBuddy -c 'Set :CFBundleName Sonus Auris Device Lab' "$INFO_PLIST"; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Sonus Auris Device Lab' "$INFO_PLIST"
fi
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 \
  | tee "$EVIDENCE_DIR/runtime-codesign.txt"

ACTUAL_RUNTIME_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if [[ "$ACTUAL_RUNTIME_BUNDLE_ID" != "$RUNTIME_BUNDLE_ID" ]]; then
  echo "Isolated Flutter runtime bundle identifier was not applied." >&2
  exit 4
fi

{
  echo "production_bundle_id=$PRODUCTION_BUNDLE_ID"
  echo "production_bundle_id_verified=true"
  echo "runtime_bundle_id=$RUNTIME_BUNDLE_ID"
  echo "runtime_identity_isolated=true"
  echo "login_item_mutation_suppressed=true"
  echo "recording_automated=false"
  echo "executable=$EXECUTABLE"
  echo "app_name=$(basename "$APP")"
  echo "package_leaf=$(basename "$PACKAGE_ROOT")"
  echo "configuration_mode=$([[ "$BACKEND_URL" == http://127.0.0.1:* ]] && echo compile-only || echo configured)"
} > "$EVIDENCE_DIR/bundle.txt"

sanitize_stream() {
  python3 -c '
import re
import sys
text = sys.stdin.read()
patterns = [
    (r"/Users/[^/\s]+", "/Users/<redacted>"),
    (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", "<redacted-jwt>"),
    (r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization_code|otp)=([^&\s]+)", r"\1=<redacted>"),
]
for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text)
sys.stdout.write(text)
'
}

candidate_executable="$APP/Contents/MacOS/$EXECUTABLE"
process_id_for_app() {
  ps -axo pid=,command= | \
    CANDIDATE_EXECUTABLE="$candidate_executable" python3 -c '
import os
import sys
needle = os.environ["CANDIDATE_EXECUTABLE"]
for raw in sys.stdin:
    stripped = raw.strip()
    if not stripped:
        continue
    parts = stripped.split(None, 1)
    if len(parts) != 2:
        continue
    pid, command = parts
    if command == needle or command.startswith(needle + " "):
        print(pid)
        break
'
}

any_sonus_flutter_app_running() {
  ps -axo pid=,command= | \
    SONUS_EXECUTABLE="$EXECUTABLE" python3 -c '
import os
import sys
suffix = "/Contents/MacOS/" + os.environ["SONUS_EXECUTABLE"]
for raw in sys.stdin:
    stripped = raw.strip()
    if not stripped:
        continue
    parts = stripped.split(None, 1)
    if len(parts) != 2:
        continue
    if suffix in parts[1]:
        print(parts[0])
'
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

# Refuse to disturb a normal installed copy. With no other matching process,
# the isolated bundle ID below unambiguously owns the launch and Quit events.
existing_pids="$(any_sonus_flutter_app_running)"
if [[ -n "$existing_pids" ]]; then
  echo "Another Sonus Auris Flutter desktop process is running. Quit it normally before the isolated runtime smoke." >&2
  exit 5
fi

open -n "$APP"
if ! pid="$(wait_for_process present 30)"; then
  echo "Packaged Flutter macOS process did not remain alive after launch." >&2
  exit 6
fi
printf 'pid=%s\n' "$pid" > "$EVIDENCE_DIR/launch-process.txt"
sleep 6

if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  screencapture -x "$EVIDENCE_DIR/launch.png" >/dev/null 2>&1 || true
fi

log show --last 3m --style compact \
  --predicate "processID == $pid" 2>/dev/null \
  | tail -n 500 \
  | sanitize_stream > "$EVIDENCE_DIR/app.log" || true

if grep -Eq 'Fatal error|abort\(\)|EXC_CRASH|SIGABRT|segmentation fault|Lost connection to device' "$EVIDENCE_DIR/app.log"; then
  kill "$pid" >/dev/null 2>&1 || true
  echo "Fatal packaged Flutter macOS evidence was found." >&2
  exit 7
fi

echo "== explicit isolated app-bundle Quit =="
if osascript -e "tell application id \"$RUNTIME_BUNDLE_ID\" to quit" > "$EVIDENCE_DIR/quit-event.txt" 2>&1; then
  quit_event_sent=true
else
  quit_event_sent=false
fi

if ! wait_for_process absent 20; then
  remaining_pid="$(process_id_for_app)"
  if [[ -n "$remaining_pid" ]]; then
    kill "$remaining_pid" >/dev/null 2>&1 || true
  fi
  echo "Packaged Flutter macOS device-lab app did not terminate within the bounded Quit window." >&2
  exit 8
fi

if [[ "$REQUIRE_APPLE_EVENT_QUIT" == "1" && "$quit_event_sent" != "true" ]]; then
  echo "Apple-event Quit could not be sent. Grant Terminal/runner Automation permission and rerun." >&2
  exit 9
fi

cat > "$EVIDENCE_DIR/result.txt" <<RESULT
status=passed
scope=isolated-packaged-flutter-macos-launch-explicit-quit
production_bundle_id=$PRODUCTION_BUNDLE_ID
runtime_bundle_id=$RUNTIME_BUNDLE_ID
runtime_identity_isolated=true
login_item_mutation_suppressed=true
recording_automated=false
quit_event_sent=$quit_event_sent
quit_bounded=true
app_data_cleared=false
preexisting_app_disturbed=false
screenshot_captured=$CAPTURE_SCREENSHOT
RESULT

echo "FLUTTER MACOS ISOLATED PACKAGED RUNTIME SMOKE PASSED"
echo "Evidence: $EVIDENCE_DIR"
