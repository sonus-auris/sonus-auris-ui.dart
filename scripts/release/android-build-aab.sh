#!/usr/bin/env bash
# Build a signed Google Play **App Bundle** (.aab).
#
# Output: build/app/outputs/bundle/release/app-release.aab
# Symbols: build/symbols/ (upload to Play for readable crash stacks)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ ! -f android/key.properties ]]; then
  echo "android/key.properties is missing; refusing to create a non-uploadable bundle." >&2
  echo "Run scripts/release/android-generate-keystore.sh first." >&2
  exit 1
fi

missing_config=()
for name in SONUS_BACKEND_BASE_URL SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
  [[ -n "${!name:-}" ]] || missing_config+=("$name")
done
if (( ${#missing_config[@]} > 0 )); then
  echo "Missing production release config: ${missing_config[*]}" >&2
  echo "A store bundle must never expose developer project fields or a broken deletion path." >&2
  exit 1
fi

build_args=()
if [[ -n "${SONUS_BUILD_NAME:-}" ]]; then
  [[ "$SONUS_BUILD_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] || {
    echo "SONUS_BUILD_NAME must be SemVer-like (for example 1.2.3)." >&2
    exit 1
  }
  build_args+=(--build-name="$SONUS_BUILD_NAME")
fi
if [[ -n "${SONUS_BUILD_NUMBER:-}" ]]; then
  [[ "$SONUS_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "SONUS_BUILD_NUMBER must be a positive integer." >&2
    exit 1
  }
  build_args+=(--build-number="$SONUS_BUILD_NUMBER")
fi

echo "Flutter: $(flutter --version | head -1)"
flutter pub get

dart_define_args=()
for name in SONUS_BACKEND_BASE_URL SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
  value="${!name:-}"
  [[ -n "$value" ]] && dart_define_args+=(--dart-define="$name=$value")
done

# --obfuscate + --split-debug-info shrinks the binary and keeps Dart stack
# traces de-obfuscatable (retain build/symbols/ beside each store build).
flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols \
  "${build_args[@]}" \
  "${dart_define_args[@]}"

aab="build/app/outputs/bundle/release/app-release.aab"
echo
echo "Built: $aab"
[[ -f "$aab" ]] && ls -la "$aab"
echo
echo "Inspect before upload:"
echo "  bundletool build-apks --bundle=$aab --output=/tmp/app.apks --mode=universal"
echo "Publish through .github/workflows/android-release.yml or Play Console internal testing."
