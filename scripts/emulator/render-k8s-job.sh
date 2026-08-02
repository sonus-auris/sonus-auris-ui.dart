#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 TEMPLATE OUTPUT IMAGE_REF" >&2
  exit 64
fi

template="$1"
output="$2"
image_ref="$3"
placeholder='${SONUS_ANDROID_EMULATOR_IMAGE}'
readonly image_pattern='^ghcr\.io/sonus-auris/android-emulator@sha256:[0-9a-f]{64}$'

if [[ ! -f "$template" || -L "$template" ]]; then
  echo "emulator Job template must be a regular, non-symlink file: $template" >&2
  exit 1
fi
if [[ ! "$image_ref" =~ $image_pattern ]]; then
  echo "emulator image must be the canonical GHCR repository pinned by sha256 digest" >&2
  exit 1
fi
if [[ "$output" == "$template" ]]; then
  echo "rendered output must not overwrite the source template" >&2
  exit 1
fi
if [[ -L "$output" ]]; then
  echo "rendered output must not replace a symlink: $output" >&2
  exit 1
fi

match_count="$( (grep -Fo "$placeholder" "$template" || true) | wc -l | tr -d '[:space:]')"
if [[ "$match_count" != '1' ]]; then
  echo "emulator Job template must contain the image placeholder exactly once; found $match_count" >&2
  exit 1
fi

mkdir -p "$(dirname "$output")"
temporary="${output}.tmp-$$"
trap 'rm -f "$temporary"' EXIT
sed "s|${placeholder}|${image_ref}|" "$template" >"$temporary"

if grep -Fq "$placeholder" "$temporary"; then
  echo "rendered emulator Job still contains the image placeholder" >&2
  exit 1
fi
if [[ "$(grep -Foc "$image_ref" "$temporary")" != '1' ]]; then
  echo "rendered emulator Job must contain the immutable image exactly once" >&2
  exit 1
fi

chmod 0600 "$temporary"
mv "$temporary" "$output"
trap - EXIT
printf 'Rendered emulator Job with immutable image %s\n' "$image_ref"
