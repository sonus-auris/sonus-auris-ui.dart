#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renderer="$repo_root/scripts/emulator/render-k8s-job.sh"
template="$repo_root/ci/android-emulator/k8s/emulator-permission-test.job.yaml"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

readonly digest="$(printf 'a%.0s' {1..64})"
readonly valid_ref="ghcr.io/sonus-auris/android-emulator@sha256:${digest}"
pass_count=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_failure() {
  local name="$1"
  shift
  local log="$temporary/$name.log"
  if "$@" >"$log" 2>&1; then
    fail "$name unexpectedly succeeded"
  fi
  pass_count=$((pass_count + 1))
}

output="$temporary/rendered.yaml"
bash "$renderer" "$template" "$output" "$valid_ref" >"$temporary/valid.log"
grep -Fq "image: $valid_ref" "$output" || fail 'valid render omitted immutable image'
! grep -Fq '${SONUS_ANDROID_EMULATOR_IMAGE}' "$output" || fail 'valid render retained placeholder'
[[ "$(stat -c '%a' "$output")" == '600' ]] || fail 'rendered manifest permissions are not 0600'
pass_count=$((pass_count + 1))

run_failure mutable_tag bash "$renderer" "$template" "$temporary/tag.yaml" \
  'ghcr.io/sonus-auris/android-emulator:latest'
grep -Fq 'pinned by sha256 digest' "$temporary/mutable_tag.log" || fail 'mutable tag failure was unclear'

run_failure other_registry bash "$renderer" "$template" "$temporary/registry.yaml" \
  "registry.example.test/sonus-auris/android-emulator@sha256:${digest}"

run_failure short_digest bash "$renderer" "$template" "$temporary/short.yaml" \
  'ghcr.io/sonus-auris/android-emulator@sha256:abc123'

cat > "$temporary/missing.yaml" <<'MISSING'
apiVersion: batch/v1
kind: Job
metadata:
  name: missing-placeholder
MISSING
run_failure missing_placeholder bash "$renderer" "$temporary/missing.yaml" \
  "$temporary/missing-output.yaml" "$valid_ref"
grep -Fq 'exactly once; found 0' "$temporary/missing_placeholder.log" || fail 'missing placeholder failure was unclear'

cat > "$temporary/duplicate.yaml" <<'DUPLICATE'
first: ${SONUS_ANDROID_EMULATOR_IMAGE}
second: ${SONUS_ANDROID_EMULATOR_IMAGE}
DUPLICATE
run_failure duplicate_placeholder bash "$renderer" "$temporary/duplicate.yaml" \
  "$temporary/duplicate-output.yaml" "$valid_ref"
grep -Fq 'exactly once; found 2' "$temporary/duplicate_placeholder.log" || fail 'duplicate placeholder failure was unclear'

run_failure overwrite_source bash "$renderer" "$template" "$template" "$valid_ref"

echo "Android emulator image policy tests passed: $pass_count cases."
