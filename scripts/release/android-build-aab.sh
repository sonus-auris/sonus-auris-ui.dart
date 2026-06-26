#!/usr/bin/env bash
# Build a signed Google Play **App Bundle** (.aab). Does NOT upload.
#
# Output: build/app/outputs/bundle/release/app-release.aab
# Symbols: build/symbols/ (upload to Play for readable crash stacks)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ ! -f android/key.properties ]]; then
  echo "WARNING: android/key.properties missing — the bundle will be DEBUG-signed and" >&2
  echo "         Play will reject it. Run scripts/release/android-generate-keystore.sh first." >&2
  read -r -p "Continue with a debug-signed (non-uploadable) build anyway? [y/N] " ans
  [[ "${ans:-N}" == "y" || "${ans:-N}" == "Y" ]] || exit 1
fi

echo "Flutter: $(flutter --version | head -1)"
flutter pub get

# --obfuscate + --split-debug-info shrinks the binary and keeps Dart stack
# traces de-obfuscatable (keep build/symbols/ to symbolicate crashes later).
flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols

aab="build/app/outputs/bundle/release/app-release.aab"
echo
echo "Built: $aab"
[[ -f "$aab" ]] && ls -la "$aab"
echo
echo "Inspect before upload:"
echo "  bundletool build-apks --bundle=$aab --output=/tmp/app.apks --mode=universal   # optional"
echo "Upload (explicit): Play Console > Internal testing, or 'cd android && fastlane internal'."
