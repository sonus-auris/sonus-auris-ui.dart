#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renderer="$repo_root/scripts/emulator/render-k8s-job.sh"
template="$repo_root/ci/android-emulator/k8s/emulator-permission-test.job.yaml"
workflow="$repo_root/.github/workflows/build-emulator-image.yml"
dockerfile="$repo_root/ci/android-emulator/Dockerfile"
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

cat >"$temporary/missing.yaml" <<'MISSING'
apiVersion: batch/v1
kind: Job
metadata:
  name: missing-placeholder
MISSING
run_failure missing_placeholder bash "$renderer" "$temporary/missing.yaml" \
  "$temporary/missing-output.yaml" "$valid_ref"
grep -Fq 'exactly once; found 0' "$temporary/missing_placeholder.log" || fail 'missing placeholder failure was unclear'

cat >"$temporary/duplicate.yaml" <<'DUPLICATE'
first: ${SONUS_ANDROID_EMULATOR_IMAGE}
second: ${SONUS_ANDROID_EMULATOR_IMAGE}
DUPLICATE
run_failure duplicate_placeholder bash "$renderer" "$temporary/duplicate.yaml" \
  "$temporary/duplicate-output.yaml" "$valid_ref"
grep -Fq 'exactly once; found 2' "$temporary/duplicate_placeholder.log" || fail 'duplicate placeholder failure was unclear'

run_failure overwrite_source bash "$renderer" "$template" "$template" "$valid_ref"

# Static supply-chain contract. This is one policy case, but it checks the
# cross-file invariants that can otherwise drift independently.
[[ "$(grep -Fo '${SONUS_ANDROID_EMULATOR_IMAGE}' "$template" | wc -l | tr -d '[:space:]')" == '1' ]] \
  || fail 'Job template must contain exactly one immutable-image placeholder'
! grep -Eq '^[[:space:]]*image:.*:latest([[:space:]]|$)' "$template" \
  || fail 'Job template must not consume a mutable image tag'
grep -Fq 'FROM ubuntu:22.04@sha256:' "$dockerfile" \
  || fail 'emulator base image is not digest pinned'
grep -Fq 'ANDROID_COMMANDLINE_TOOLS_SHA256=' "$dockerfile" \
  || fail 'Android command-line tools checksum is not declared'
grep -Fq 'COPY build/app/outputs/flutter-apk/app-debug.apk /work/app-under-test.apk' "$dockerfile" \
  || fail 'exact debug APK is not embedded in the image'
grep -Fq 'sha256sum --check --strict' "$dockerfile" \
  || fail 'download/APK checks are not fail-closed'
grep -Fq 'Build exact debug APK' "$workflow" \
  || fail 'workflow does not build the APK before Buildx'
[[ "$(grep -Fc 'packages: write' "$workflow")" == '1' ]] \
  || fail 'packages: write must exist only on the trusted publish job'
grep -Fq 'load: true' "$workflow" \
  || fail 'pull-request image is not loaded for local inspection'
grep -Fq 'provenance: mode=max' "$workflow" \
  || fail 'trusted image publication lacks provenance'
grep -Fq 'sbom: true' "$workflow" \
  || fail 'trusted image publication lacks an SBOM'
grep -Fq 'IMAGE_REF: ${{ needs.publish-image.outputs.image_ref }}' "$workflow" \
  || fail 'cluster job does not consume the exact published digest'
pass_count=$((pass_count + 1))

[[ "$pass_count" == '8' ]] || fail "expected 8 policy cases, ran $pass_count"
echo "Android emulator image policy tests passed: $pass_count cases."
