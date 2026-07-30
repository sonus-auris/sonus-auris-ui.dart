#!/usr/bin/env bash
# Build a signed Android APK for direct installation on a physical device.
#
# Output: build/app/outputs/flutter-apk/app-release.apk
# Symbols: build/symbols/ (retain beside the corresponding release)
#
# This uses the same upload keystore and public production configuration as the
# Play AAB. It is intended for controlled physical-device acceptance before the
# Play internal track is ready. If Google Play App Signing later serves a build
# signed by a different app-signing certificate, uninstall this sideloaded build
# before installing from Play.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ ! -f android/key.properties ]]; then
  echo "android/key.properties is missing; refusing to create an unsigned or debug-signed release APK." >&2
  echo "Run scripts/release/android-generate-keystore.sh first." >&2
  exit 1
fi

missing_config=()
for name in SONUS_BACKEND_BASE_URL SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
  [[ -n "${!name:-}" ]] || missing_config+=("$name")
done
if (( ${#missing_config[@]} > 0 )); then
  echo "Missing production release config: ${missing_config[*]}" >&2
  echo "A physical-device candidate must not contain placeholder account or deletion endpoints." >&2
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

flutter build apk \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols \
  "${build_args[@]}" \
  "${dart_define_args[@]}"

apk="build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$apk" ]] || {
  echo "Expected APK was not produced: $apk" >&2
  exit 1
}

apksigner_bin="$(command -v apksigner || true)"
if [[ -z "$apksigner_bin" && -n "${ANDROID_HOME:-}" ]]; then
  apksigner_bin="$(find "$ANDROID_HOME/build-tools" -type f -name apksigner -print 2>/dev/null | sort -V | tail -n1)"
fi
[[ -n "$apksigner_bin" ]] || {
  echo "apksigner is required to verify the direct-install candidate." >&2
  exit 1
}
"$apksigner_bin" verify --verbose --print-certs "$apk"

echo
echo "Built and signature-verified: $apk"
ls -la "$apk"
