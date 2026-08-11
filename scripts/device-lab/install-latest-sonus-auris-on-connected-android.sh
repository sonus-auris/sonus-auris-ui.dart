#!/usr/bin/env bash
# Pull canonical Sonus Auris main, load the active public client configuration
# from sonus-auris.infra, test/build a debug APK, and safely install it on one
# ADB-authorized Android device.
#
# No credential is embedded in this file. Private GitHub access uses, in order:
#   1. GITHUB_TOKEN from the caller's environment
#   2. the token from an existing `gh auth login`
#   3. the Mac's existing git/Keychain credentials
#
# This script never uninstalls the existing Android package.
#
# Typical Mac usage (credentials stay in the calling shell):
#   GITHUB_TOKEN=... LINEAR_API_KEY=... \
#     scripts/device-lab/install-latest-sonus-auris-on-connected-android.sh
#
# Set ANDROID_SERIAL when more than one authorized device is connected. Set
# SONUS_INFRA_DIR only to deliberately use a reviewed local infra checkout; the
# default is a freshly reset clone of canonical sonus-auris.infra/main.
set -euo pipefail

APP_SLUG="sonus-auris/sonus-auris-flutter.dart"
INFRA_SLUG="sonus-auris/sonus-auris.infra"
PACKAGE_ID="com.ores.sonus_auris"
BRANCH="${SONUS_BRANCH:-main}"
CACHE_ROOT="${SONUS_INSTALL_CACHE:-$HOME/Library/Caches/sonus-auris-installer}"
APP_REPO="$CACHE_ROOT/sonus-auris-flutter.dart"
INFRA_REPO="${SONUS_INFRA_DIR:-}"
ENV_NAME="${SONUS_ENV:-}"
ASKPASS=""
LINEAR_CURL_CONFIG=""

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

cleanup() {
  [[ -z "$ASKPASS" ]] || rm -f "$ASKPASS"
  [[ -z "$LINEAR_CURL_CONFIG" ]] || rm -f "$LINEAR_CURL_CONFIG"
}
trap cleanup EXIT INT TERM

find_flutter() {
  local candidate
  for candidate in \
    "${FLUTTER_BIN:-}" \
    "/Users/maca5/development/flutter/bin/flutter" \
    "$(command -v flutter 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

find_adb() {
  local candidate
  for candidate in \
    "${ADB_BIN:-}" \
    "$(command -v adb 2>/dev/null || true)" \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

configure_github_auth() {
  # Reuse a secure existing gh session when the caller did not export a token.
  if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    local gh_token
    gh_token="$(gh auth token 2>/dev/null || true)"
    [[ -z "$gh_token" ]] || export GITHUB_TOKEN="$gh_token"
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    ASKPASS="$(mktemp "${TMPDIR:-/tmp}/sonus-auris-askpass.XXXXXX")"
    cat >"$ASKPASS" <<'ASKPASS_EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "${GITHUB_TOKEN:?}" ;;
  *) printf '%s\n' "${GITHUB_TOKEN:?}" ;;
esac
ASKPASS_EOF
    chmod 700 "$ASKPASS"
  fi
}

git_remote() {
  printf 'https://github.com/%s.git\n' "$1"
}

git_auth() {
  if [[ -n "$ASKPASS" ]]; then
    GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git "$@"
  else
    git "$@"
  fi
}

refresh_cache_repo() {
  local slug="$1" dir="$2" branch="$3"
  mkdir -p "$(dirname "$dir")"
  if [[ -d "$dir/.git" ]]; then
    note "Refreshing $slug:$branch"
    git_auth -C "$dir" fetch --prune --depth=1 origin "$branch"
    git -C "$dir" checkout -B installer-main FETCH_HEAD >/dev/null
    git -C "$dir" reset --hard FETCH_HEAD >/dev/null
    git -C "$dir" clean -ffdx >/dev/null
  else
    rm -rf "$dir"
    note "Cloning $slug:$branch into the isolated installer cache"
    git_auth clone --depth=1 --branch "$branch" "$(git_remote "$slug")" "$dir"
  fi
  git_auth -C "$dir" submodule update --init --recursive --depth=1
}

load_public_client_config() {
  # Honor an explicit caller environment first.
  local infra="$1" encrypted="" decrypted=""
  if [[ -n "${SONUS_BACKEND_BASE_URL:-}" && \
        -n "${SONUS_SUPABASE_URL:-}" && \
        -n "${SONUS_SUPABASE_ANON_KEY:-}" ]]; then
    CONFIG_SOURCE="caller environment"
  elif [[ -f "$infra/.env" ]]; then
    CONFIG_SOURCE="$infra/.env"
    set -a
    # shellcheck disable=SC1090
    source "$infra/.env"
    set +a
  else
    if [[ -z "$ENV_NAME" ]]; then
      if [[ -f "$infra/env/enc/prod.env.enc" ]]; then
        ENV_NAME="prod"
      elif [[ -f "$infra/env/enc/dev.env.enc" ]]; then
        ENV_NAME="dev"
      else
        fail "No active .env and no prod/dev encrypted environment found in $infra"
      fi
    fi
    encrypted="$infra/env/enc/$ENV_NAME.env.enc"
    [[ -f "$encrypted" ]] || fail "Encrypted Sonus environment not found: $encrypted"
    command -v sops >/dev/null 2>&1 || fail "sops is required to decrypt $encrypted"
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$HOME/.config/sops/age/keys.txt" ]]; then
      export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
    fi
    CONFIG_SOURCE="$encrypted (decrypted in memory)"
    decrypted="$(sops decrypt --input-type dotenv --output-type dotenv "$encrypted")" \
      || fail "Could not decrypt $encrypted"
    set -a
    # shellcheck disable=SC1091
    source /dev/stdin <<<"$decrypted"
    set +a
    unset decrypted
  fi

  local missing=() name
  for name in SONUS_BACKEND_BASE_URL SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  (( ${#missing[@]} == 0 )) || fail "Missing public client config in $CONFIG_SOURCE: ${missing[*]}"

  case "$SONUS_SUPABASE_ANON_KEY" in
    sb_secret_*) fail "SONUS_SUPABASE_ANON_KEY contains a secret key; only an anon/publishable key may enter the app." ;;
  esac
  [[ "$SONUS_SUPABASE_URL" == https://* ]] || fail "SONUS_SUPABASE_URL must use HTTPS."
  [[ "$SONUS_BACKEND_BASE_URL" == https://* ]] || fail "SONUS_BACKEND_BASE_URL must use HTTPS for a physical handset."
  case "$SONUS_BACKEND_BASE_URL" in
    *localhost*|*127.0.0.1*|*10.0.2.2*)
      fail "The backend URL points at loopback/emulator networking and is not suitable for a physical handset. Activate the public/tunnel environment."
      ;;
  esac
}

select_device() {
  local adb="$1" state line
  DEVICE_SERIAL=""
  "$adb" start-server >/dev/null

  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    state="$("$adb" -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)"
    [[ "$state" == "device" ]] || fail "ANDROID_SERIAL=$ANDROID_SERIAL is not authorized/online (state: ${state:-unknown})."
    DEVICE_SERIAL="$ANDROID_SERIAL"
    return 0
  fi

  local devices=()
  while IFS= read -r line; do
    [[ -z "$line" ]] || devices+=("$line")
  done < <("$adb" devices | awk 'NR>1 && $2=="device" {print $1}')

  if (( ${#devices[@]} == 0 )); then
    "$adb" devices -l >&2 || true
    fail "No authorized Android device is visible. Unlock it, enable USB debugging, and approve the Mac's RSA prompt."
  fi
  if (( ${#devices[@]} > 1 )); then
    printf 'Authorized devices:\n' >&2
    printf '  %s\n' "${devices[@]}" >&2
    fail "More than one device is connected. Re-run with ANDROID_SERIAL=<serial>."
  fi
  DEVICE_SERIAL="${devices[0]}"
}

safe_install() {
  local adb="$1" serial="$2" apk="$3" output status
  set +e
  output="$("$adb" -s "$serial" install -r "$apk" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  if (( status != 0 )); then
    if grep -qE 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match' <<<"$output"; then
      cat >&2 <<MSG

The installed Sonus Auris package uses a different signing certificate.
Nothing was uninstalled. Uninstalling $PACKAGE_ID can erase app-private audio,
encryption keys, settings, and sign-in state. Export anything important before
making an explicit uninstall/reinstall decision.
MSG
    fi
    return "$status"
  fi
}


redact_line() {
  printf '%s' "$1" | tr -d '\r\n'
}

device_evidence() {
  local adb="$1" serial="$2"
  DEVICE_MODEL="$(redact_line "$("$adb" -s "$serial" shell getprop ro.product.model 2>/dev/null || true)")"
  ANDROID_VERSION="$(redact_line "$("$adb" -s "$serial" shell getprop ro.build.version.release 2>/dev/null || true)")"
  ANDROID_SDK="$(redact_line "$("$adb" -s "$serial" shell getprop ro.build.version.sdk 2>/dev/null || true)")"
  SECURITY_PATCH="$(redact_line "$("$adb" -s "$serial" shell getprop ro.build.version.security_patch 2>/dev/null || true)")"
  AVAILABLE_DATA="$("$adb" -s "$serial" shell df -h /data 2>/dev/null | awk 'NR>1 {last=$4} END {print last}' | tr -d '\r' || true)"
  BATTERY_LEVEL="$("$adb" -s "$serial" shell dumpsys battery 2>/dev/null | awk '/^[[:space:]]*level:/ {print $2; exit}' | tr -d '\r' || true)"
  INSTALLED_VERSION="$("$adb" -s "$serial" shell dumpsys package "$PACKAGE_ID" 2>/dev/null | awk -F= '/versionName=/{print $2; exit}' | tr -d '\r' || true)"
}

linear_update_if_configured() {
  [[ -n "${LINEAR_API_KEY:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || { printf 'warning: curl missing; Linear update skipped.\n' >&2; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf 'warning: python3 missing; Linear update skipped.\n' >&2; return 0; }

  local issue_response issue_uuid mutation_payload mutation_response comment_body
  LINEAR_CURL_CONFIG="$(mktemp "${TMPDIR:-/tmp}/sonus-linear-curl.XXXXXX")"
  chmod 600 "$LINEAR_CURL_CONFIG"
  {
    printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY"
    printf 'header = "Content-Type: application/json"\n'
  } >"$LINEAR_CURL_CONFIG"

  comment_body="$(cat <<LINEAR_COMMENT
### Physical-device install execution

- Canonical source: \`$APP_SLUG@$SOURCE_SHA\`
- App version: \`$VERSION\`; package: \`$PACKAGE_ID\`
- Device: \`${DEVICE_MODEL:-unknown}\`; Android \`${ANDROID_VERSION:-unknown}\` (SDK \`${ANDROID_SDK:-unknown}\`); security patch \`${SECURITY_PATCH:-unknown}\`
- Available \`/data\`: \`${AVAILABLE_DATA:-unknown}\`; battery: \`${BATTERY_LEVEL:-unknown}%\`
- Install route: explicit ADB \`install -r\`; no uninstall or app-data deletion
- APK SHA-256: \`$APK_SHA\`
- Installed version reported by package manager: \`${INSTALLED_VERSION:-unknown}\`

This is a canonical-main **debug source build** using the active Sonus public client configuration. It enables immediate handset development/smoke work, but it is not the protected production-signed APK required by DEN-775/DEN-836 and does not close the release-candidate acceptance gate. Full recording, background, permission, playback, encryption/upload, schedule, battery/thermal, and sanitized-evidence checks remain pending.
LINEAR_COMMENT
)"

  issue_response="$(python3 - <<'PY_QUERY' | curl -sS --max-time 30 \
    --config "$LINEAR_CURL_CONFIG" \
    --data-binary @- https://api.linear.app/graphql
import json
print(json.dumps({
    "query": "query($identifier: String!) { issue(id: $identifier) { id } }",
    "variables": {"identifier": "DEN-836"},
}))
PY_QUERY
)" || { printf 'warning: Linear lookup failed; install remains successful.\n' >&2; return 0; }

  issue_uuid="$(LINEAR_RESPONSE="$issue_response" python3 - <<'PY_PARSE'
import json, os
try:
    obj=json.loads(os.environ.get('LINEAR_RESPONSE',''))
    print(obj['data']['issue']['id'])
except Exception:
    pass
PY_PARSE
)"
  [[ -n "$issue_uuid" ]] || { printf 'warning: DEN-836 could not be resolved; Linear update skipped.\n' >&2; return 0; }

  mutation_payload="$(LINEAR_ISSUE_ID="$issue_uuid" LINEAR_COMMENT_BODY="$comment_body" python3 - <<'PY_MUTATION'
import json, os
print(json.dumps({
    "query": "mutation($issueId: String!, $stateId: String!, $body: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } commentCreate(input: {issueId: $issueId, body: $body}) { success } }",
    "variables": {
        "issueId": os.environ["LINEAR_ISSUE_ID"],
        "stateId": "afb7ed8a-ca77-4a74-b401-b4a7dda32e21",
        "body": os.environ["LINEAR_COMMENT_BODY"],
    },
}))
PY_MUTATION
)"

  mutation_response="$(curl -sS --max-time 30 \
    --config "$LINEAR_CURL_CONFIG" \
    --data-binary "$mutation_payload" https://api.linear.app/graphql)" \
    || { printf 'warning: Linear mutation failed; install remains successful.\n' >&2; return 0; }

  if LINEAR_RESPONSE="$mutation_response" python3 - <<'PY_CHECK'
import json, os, sys
try:
    obj=json.loads(os.environ.get('LINEAR_RESPONSE',''))
    ok=(obj.get('data',{}).get('issueUpdate',{}).get('success') is True and
        obj.get('data',{}).get('commentCreate',{}).get('success') is True and
        not obj.get('errors'))
except Exception:
    ok=False
sys.exit(0 if ok else 1)
PY_CHECK
  then
    printf 'Updated Linear DEN-836 to In Progress with a sanitized install note.\n'
  else
    printf 'warning: Linear returned an error; install remains successful.\n' >&2
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this installer on the Mac that owns Flutter, Android platform-tools, and the authorized handset."
FLUTTER="$(find_flutter)" || fail "Flutter was not found. Set FLUTTER_BIN or restore /Users/maca5/development/flutter."
ADB="$(find_adb)" || fail "adb was not found. Install Android platform-tools or set ADB_BIN."
configure_github_auth
refresh_cache_repo "$APP_SLUG" "$APP_REPO" "$BRANCH"

if [[ -n "$INFRA_REPO" ]]; then
  [[ -d "$INFRA_REPO" ]] || fail "SONUS_INFRA_DIR does not exist: $INFRA_REPO"
  note "Using explicitly selected infra checkout: $INFRA_REPO"
else
  INFRA_REPO="$CACHE_ROOT/sonus-auris.infra"
  refresh_cache_repo "$INFRA_SLUG" "$INFRA_REPO" main
fi

load_public_client_config "$INFRA_REPO"
select_device "$ADB"

SOURCE_SHA="$(git -C "$APP_REPO" rev-parse HEAD)"
SOURCE_SHORT="$(git -C "$APP_REPO" rev-parse --short=12 HEAD)"
VERSION="$(awk '/^version:[[:space:]]*/ {print $2; exit}' "$APP_REPO/pubspec.yaml")"

note "Source: $APP_SLUG@$SOURCE_SHA"
printf 'Version: %s\n' "$VERSION"
printf 'Config:  %s\n' "$CONFIG_SOURCE"
printf 'Device:  %s\n' "$DEVICE_SERIAL"
printf 'Flutter: %s\n' "$("$FLUTTER" --version | head -1)"

cd "$APP_REPO"
"$FLUTTER" pub get
if [[ "${SONUS_SKIP_TESTS:-0}" != "1" ]]; then
  note "Running analyzer"
  "$FLUTTER" analyze --no-fatal-infos
  note "Running Flutter tests"
  "$FLUTTER" test
else
  printf 'warning: SONUS_SKIP_TESTS=1; analyzer/tests were skipped.\n' >&2
fi

note "Building Android debug APK with the active public client configuration"
"$FLUTTER" build apk --debug \
  --dart-define="SONUS_BACKEND_BASE_URL=$SONUS_BACKEND_BASE_URL" \
  --dart-define="SONUS_SUPABASE_URL=$SONUS_SUPABASE_URL" \
  --dart-define="SONUS_SUPABASE_ANON_KEY=$SONUS_SUPABASE_ANON_KEY"

APK="$APP_REPO/build/app/outputs/flutter-apk/app-debug.apk"
[[ -f "$APK" ]] || fail "Expected APK was not produced: $APK"
APK_SHA="$(shasum -a 256 "$APK" | awk '{print $1}')"
SAFE_VERSION="$(printf '%s' "$VERSION" | tr '+/' '--')"
OUT="$HOME/Downloads/sonus-auris-${SAFE_VERSION}-${SOURCE_SHORT}-debug.apk"
cp -f "$APK" "$OUT"
printf '%s  %s\n' "$APK_SHA" "$(basename "$OUT")" >"$OUT.sha256"

note "Installing without deleting existing app data"
safe_install "$ADB" "$DEVICE_SERIAL" "$OUT"
"$ADB" -s "$DEVICE_SERIAL" shell monkey \
  -p "$PACKAGE_ID" \
  -c android.intent.category.LAUNCHER \
  1 >/dev/null 2>&1 || true

device_evidence "$ADB" "$DEVICE_SERIAL"
linear_update_if_configured

cat <<DONE

Installed and launched Sonus Auris.
  Device:  $DEVICE_SERIAL
  Package: $PACKAGE_ID
  Version: $VERSION
  Commit:  $SOURCE_SHA
  APK:     $OUT
  SHA-256: $APK_SHA
  Device:  ${DEVICE_MODEL:-unknown}, Android ${ANDROID_VERSION:-unknown}, patch ${SECURITY_PATCH:-unknown}

Grant microphone and notification access on the phone when prompted.
Set LINEAR_API_KEY before running to post the sanitized install result to DEN-836.
DONE
