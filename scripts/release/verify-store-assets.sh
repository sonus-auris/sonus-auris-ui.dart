#!/usr/bin/env bash
# Validate the tracked App Store / Play Store graphics before upload. In
# particular, OCR the account screenshots so a retired password screen cannot
# silently return to either listing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

command -v python3 >/dev/null || {
  echo "python3 is required to inspect PNG dimensions." >&2
  exit 1
}
command -v tesseract >/dev/null || {
  echo "tesseract is required to verify screenshot copy (macOS: brew install tesseract)." >&2
  exit 1
}

check_png_dimensions() {
  local file="$1"
  local expected_width="$2"
  local expected_height="$3"
  python3 - "$file" "$expected_width" "$expected_height" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
data = path.read_bytes()
if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
    raise SystemExit(f"{path}: not a valid PNG header")
actual = struct.unpack(">II", data[16:24])
if actual != expected:
    raise SystemExit(
        f"{path}: expected {expected[0]}x{expected[1]}, got {actual[0]}x{actual[1]}"
    )
print(f"  ✓ {path}: {actual[0]}x{actual[1]}")
PY
}

android_images="android/fastlane/metadata/android/en-US/images"
ios_images="ios/fastlane/screenshots/en-US"

check_png_dimensions "$android_images/icon.png" 512 512
check_png_dimensions "$android_images/featureGraphic.png" 1024 500
check_png_dimensions "$android_images/phoneScreenshots/1-welcome.png" 1080 1920
check_png_dimensions "$android_images/phoneScreenshots/2-sign-in.png" 1080 1920
check_png_dimensions "$ios_images/iPhone-17-Pro-Max-1-welcome.png" 1320 2868
check_png_dimensions "$ios_images/iPhone-17-Pro-Max-2-sign-in.png" 1320 2868

check_auth_screenshot() {
  local file="$1"
  local copy
  copy="$(tesseract "$file" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  if ! grep -Eq '6.?digit|six.?digit' <<< "$copy"; then
    echo "$file: OCR did not find the required passwordless 6-digit email-code copy." >&2
    exit 1
  fi
  if grep -Eq 'forgot password|project url|publishable or anon key|email me a magic link|one email magic link' <<< "$copy"; then
    echo "$file: OCR found retired password, magic-link-first, or developer configuration copy." >&2
    exit 1
  fi
  echo "  ✓ $file: passwordless 6-digit email-code copy verified"
}

check_auth_screenshot "$android_images/phoneScreenshots/2-sign-in.png"
check_auth_screenshot "$ios_images/iPhone-17-Pro-Max-2-sign-in.png"

echo "Store asset verification passed."
