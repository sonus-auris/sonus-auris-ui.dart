#!/usr/bin/env bash
# Bump the app version in pubspec.yaml. The single source of truth for both
# stores: `version: <marketing>+<build>` → Android versionName/versionCode and
# iOS CFBundleShortVersionString/CFBundleVersion (via flutter.* in the build).
#
#   bump-version.sh 1.2.0          # set marketing 1.2.0, auto-increment build
#   bump-version.sh 1.2.0 7        # set marketing 1.2.0, build 7
#   bump-version.sh --build        # keep marketing, just increment build
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pubspec="$repo_root/pubspec.yaml"

current_line="$(grep -E '^version:' "$pubspec" | head -1)"
current="${current_line#version: }"
cur_name="${current%%+*}"
cur_build="${current##*+}"

case "${1:-}" in
  --build|"")
    new_name="$cur_name"; new_build=$((cur_build + 1)) ;;
  *)
    new_name="$1"
    if [[ -n "${2:-}" ]]; then new_build="$2"; else new_build=$((cur_build + 1)); fi ;;
esac

new_version="${new_name}+${new_build}"
NEW_VERSION="$new_version" perl -0pi -e 's/^version: .*/version: $ENV{NEW_VERSION}/m' "$pubspec"

echo "Version: ${current}  ->  ${new_version}"
echo "  Android versionName=${new_name} versionCode=${new_build}"
echo "  iOS    CFBundleShortVersionString=${new_name} CFBundleVersion=${new_build}"
echo
echo "Note: Play requires a strictly increasing versionCode for every upload;"
echo "the App Store requires a build number unique within a marketing version."
