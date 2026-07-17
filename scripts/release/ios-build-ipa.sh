#!/usr/bin/env bash
# Build a signed App Store **IPA**. Does NOT upload. macOS + Xcode only.
#
# Output: build/ios/ipa/*.ipa
# Requires: a Distribution cert + App Store provisioning profile for
# com.ores.audioDashcam, and DEVELOPMENT_TEAM set (env or in the Xcode project).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

[[ "$(uname)" == "Darwin" ]] || { echo "iOS builds require macOS + Xcode." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode (xcodebuild) not found." >&2; exit 1; }

export_opts="ios/ExportOptions.plist"
[[ -f "$export_opts" ]] || { echo "Missing $export_opts" >&2; exit 1; }
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple Developer Team ID used for com.ores.audioDashcam}"

missing_config=()
for name in SONUS_BACKEND_BASE_URL SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
  [[ -n "${!name:-}" ]] || missing_config+=("$name")
done
if (( ${#missing_config[@]} > 0 )); then
  echo "Missing production release config: ${missing_config[*]}" >&2
  echo "A store IPA must never expose developer project fields or a broken deletion path." >&2
  exit 1
fi

echo "Flutter: $(flutter --version | head -1)"
flutter pub get
( cd ios && pod install )

dart_define_args=()
for name in SONUS_BACKEND_BASE_URL SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
  value="${!name:-}"
  [[ -n "$value" ]] && dart_define_args+=(--dart-define="$name=$value")
done

flutter build ipa \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols \
  --export-options-plist="$export_opts" \
  "${dart_define_args[@]}"

echo
echo "Built IPA(s):"; ls -la build/ios/ipa/*.ipa 2>/dev/null || echo "  (none — check signing/profile errors above)"
echo
echo "Upload (explicit): Xcode Organizer / Transporter, or 'cd ios && fastlane beta' for TestFlight."
echo "Tip: validate first with 'xcrun altool --validate-app' or Transporter's Verify."
