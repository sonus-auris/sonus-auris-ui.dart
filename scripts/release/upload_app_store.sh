#!/usr/bin/env bash
# Validate and upload one signed IPA to App Store Connect with an API key.
# This uploads a build for TestFlight/App Store processing; it does not submit
# an app version for review or release it to customers.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

[[ "$(uname)" == "Darwin" ]] || { echo "App Store upload requires macOS + Xcode." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "xcrun is unavailable." >&2; exit 1; }

: "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID}"
: "${APP_STORE_CONNECT_API_KEY_P8_BASE64:?Set APP_STORE_CONNECT_API_KEY_P8_BASE64}"

ipa="${1:-}"
if [[ -z "$ipa" ]]; then
  shopt -s nullglob
  ipas=(build/ios/ipa/*.ipa)
  (( ${#ipas[@]} == 1 )) || {
    echo "Expected exactly one build/ios/ipa/*.ipa; found ${#ipas[@]}." >&2
    exit 1
  }
  ipa="${ipas[0]}"
fi
[[ -f "$ipa" ]] || { echo "IPA does not exist: $ipa" >&2; exit 1; }

key_dir="$HOME/.appstoreconnect/private_keys"
key_path="$key_dir/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
mkdir -p "$key_dir"
umask 077
printf '%s' "$APP_STORE_CONNECT_API_KEY_P8_BASE64" | base64 -D > "$key_path"
trap 'rm -f "$key_path"' EXIT

# altool resolves AuthKey_<key-id>.p8 from ~/.appstoreconnect/private_keys.
xcrun altool \
  --validate-app \
  --file "$ipa" \
  --type ios \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"

xcrun altool \
  --upload-app \
  --file "$ipa" \
  --type ios \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"

echo "Uploaded $(basename "$ipa") to App Store Connect for processing."
