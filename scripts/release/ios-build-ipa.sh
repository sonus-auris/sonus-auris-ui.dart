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

echo "Flutter: $(flutter --version | head -1)"
flutter pub get
( cd ios && pod install )

# If DEVELOPMENT_TEAM is exported, thread it through; otherwise rely on the
# team configured in the Xcode project / ExportOptions.plist.
team_args=()
[[ -n "${DEVELOPMENT_TEAM:-}" ]] && team_args=(--dart-define=TEAM="$DEVELOPMENT_TEAM")

flutter build ipa \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols \
  --export-options-plist="$export_opts" \
  "${team_args[@]}"

echo
echo "Built IPA(s):"; ls -la build/ios/ipa/*.ipa 2>/dev/null || echo "  (none — check signing/profile errors above)"
echo
echo "Upload (explicit): Xcode Organizer / Transporter, or 'cd ios && fastlane beta' for TestFlight."
echo "Tip: validate first with 'xcrun altool --validate-app' or Transporter's Verify."
