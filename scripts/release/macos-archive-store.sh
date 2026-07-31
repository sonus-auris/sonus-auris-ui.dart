#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_dir"

: "${APPLE_DEVELOPMENT_TEAM:?Set APPLE_DEVELOPMENT_TEAM to the Apple Developer Team ID.}"

identity="${APPLE_DISTRIBUTION_IDENTITY:-Apple Distribution}"
archive_path="${SONUS_MACOS_ARCHIVE_PATH:-$repo_dir/build/macos/archive/Sonus Auris.xcarchive}"
export_path="${SONUS_MACOS_EXPORT_PATH:-$repo_dir/build/macos/store-export}"

if ! security find-identity -v -p codesigning | grep -Fq "$identity"; then
  echo "No '$identity' signing identity is available in this keychain." >&2
  exit 1
fi

# Prime Flutter's generated build settings and plugin artifacts with the real
# desktop entrypoint. This remains a locally buildable release using the
# minimal entitlement set.
flutter build macos --release -t lib/main_desktop.dart

# Store-only iCloud entitlements require a matching App ID, container, and
# provisioning profile. Keep them out of ad-hoc developer builds.
xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath "$archive_path" \
  archive \
  DEVELOPMENT_TEAM="$APPLE_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$identity" \
  CODE_SIGN_ENTITLEMENTS=Runner/Store.entitlements

xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist macos/ExportOptions.plist

echo "Signed macOS store export: $export_path"
