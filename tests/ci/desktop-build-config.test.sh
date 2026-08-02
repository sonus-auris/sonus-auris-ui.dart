#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
resolver="$repo_root/scripts/ci/resolve-desktop-build-config.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

pass_count=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_line() {
  local file="$1"
  local expected="$2"
  grep -Fxq "$expected" "$file" || fail "$file did not contain: $expected"
}

assert_absent() {
  local file="$1"
  local forbidden="$2"
  if grep -Fq "$forbidden" "$file"; then
    fail "$file leaked or retained forbidden text: $forbidden"
  fi
}

assert_no_partial_outputs() {
  local name="$1"
  [[ ! -s "$temporary/$name.env" ]] || fail "$name wrote a partial GITHUB_ENV"
  [[ ! -s "$temporary/$name.output" ]] || fail "$name wrote a partial GITHUB_OUTPUT"
}

run_success() {
  local name="$1"
  shift
  local env_file="$temporary/$name.env"
  local output_file="$temporary/$name.output"
  local log_file="$temporary/$name.log"
  : > "$env_file"
  : > "$output_file"
  if ! env -i \
    PATH="$PATH" \
    HOME="${HOME:-$temporary}" \
    GITHUB_ENV="$env_file" \
    GITHUB_OUTPUT="$output_file" \
    "$@" \
    bash "$resolver" > "$log_file" 2>&1; then
    cat "$log_file" >&2
    fail "$name unexpectedly failed"
  fi
  pass_count=$((pass_count + 1))
}

run_failure() {
  local name="$1"
  shift
  local env_file="$temporary/$name.env"
  local output_file="$temporary/$name.output"
  local log_file="$temporary/$name.log"
  : > "$env_file"
  : > "$output_file"
  if env -i \
    PATH="$PATH" \
    HOME="${HOME:-$temporary}" \
    GITHUB_ENV="$env_file" \
    GITHUB_OUTPUT="$output_file" \
    "$@" \
    bash "$resolver" > "$log_file" 2>&1; then
    fail "$name unexpectedly succeeded"
  fi
  pass_count=$((pass_count + 1))
}

run_success compile_only SONUS_REQUIRE_REAL_CONFIG=false
assert_line "$temporary/compile_only.env" 'SONUS_BACKEND_BASE_URL=http://127.0.0.1:8126'
assert_line "$temporary/compile_only.env" 'SONUS_SUPABASE_URL=http://127.0.0.1:54321'
assert_line "$temporary/compile_only.env" 'SONUS_SUPABASE_ANON_KEY=sb_publishable_compile_only'
assert_line "$temporary/compile_only.env" 'SONUS_DESKTOP_BUILD_CONFIG_MODE=compile-only'
assert_line "$temporary/compile_only.output" 'mode=compile-only'
assert_line "$temporary/compile_only.output" 'distributable=false'
assert_line "$temporary/compile_only.log" 'Desktop build configuration: compile-only placeholders; distributable artifact upload is disabled.'

# A partial configuration is more dangerous than a wholly inert one. If any
# value is missing, every compile-time endpoint/key must use the local sentinel.
run_success partial_config \
  SONUS_REQUIRE_REAL_CONFIG=false \
  SONUS_BACKEND_BASE_URL=https://real-backend.example.test \
  SONUS_SUPABASE_ANON_KEY=provided-but-incomplete
assert_line "$temporary/partial_config.env" 'SONUS_BACKEND_BASE_URL=http://127.0.0.1:8126'
assert_line "$temporary/partial_config.env" 'SONUS_SUPABASE_URL=http://127.0.0.1:54321'
assert_line "$temporary/partial_config.env" 'SONUS_SUPABASE_ANON_KEY=sb_publishable_compile_only'
assert_line "$temporary/partial_config.output" 'distributable=false'
assert_absent "$temporary/partial_config.env" 'real-backend.example.test'
assert_absent "$temporary/partial_config.env" 'provided-but-incomplete'

run_success configured \
  SONUS_REQUIRE_REAL_CONFIG=false \
  SONUS_BACKEND_BASE_URL=https://backend.example.test/api \
  SONUS_SUPABASE_URL=https://project.supabase.co \
  SONUS_SUPABASE_ANON_KEY=sb_publishable_configured_fixture
assert_line "$temporary/configured.env" 'SONUS_DESKTOP_BUILD_CONFIG_MODE=configured'
assert_line "$temporary/configured.env" 'SONUS_BACKEND_BASE_URL=https://backend.example.test/api'
assert_line "$temporary/configured.env" 'SONUS_SUPABASE_URL=https://project.supabase.co'
assert_line "$temporary/configured.env" 'SONUS_SUPABASE_ANON_KEY=sb_publishable_configured_fixture'
assert_line "$temporary/configured.output" 'mode=configured'
assert_line "$temporary/configured.output" 'distributable=true'
assert_absent "$temporary/configured.log" 'backend.example.test'
assert_absent "$temporary/configured.log" 'sb_publishable_configured_fixture'

run_failure publish_missing \
  SONUS_REQUIRE_REAL_CONFIG=true \
  SONUS_BACKEND_BASE_URL=https://publish-backend.example.test \
  SONUS_SUPABASE_ANON_KEY=publish-secret-must-not-log
assert_line "$temporary/publish_missing.log" 'Publishing requires real desktop build configuration; missing: SONUS_SUPABASE_URL'
assert_absent "$temporary/publish_missing.log" 'publish-backend.example.test'
assert_absent "$temporary/publish_missing.log" 'publish-secret-must-not-log'
assert_no_partial_outputs publish_missing

run_success publish \
  SONUS_REQUIRE_REAL_CONFIG=true \
  SONUS_BACKEND_BASE_URL=https://publish-backend.example.test \
  SONUS_SUPABASE_URL=https://publish-project.supabase.co \
  SONUS_SUPABASE_ANON_KEY=sb_publishable_publish_fixture
assert_line "$temporary/publish.env" 'SONUS_DESKTOP_BUILD_CONFIG_MODE=publish'
assert_line "$temporary/publish.output" 'mode=publish'
assert_line "$temporary/publish.output" 'distributable=true'
assert_absent "$temporary/publish.log" 'publish-backend.example.test'
assert_absent "$temporary/publish.log" 'sb_publishable_publish_fixture'

run_failure credential_url \
  SONUS_REQUIRE_REAL_CONFIG=false \
  SONUS_BACKEND_BASE_URL=https://user:embedded-secret@example.test \
  SONUS_SUPABASE_URL=https://project.supabase.co \
  SONUS_SUPABASE_ANON_KEY=sb_publishable_configured_fixture
assert_line "$temporary/credential_url.log" 'SONUS_BACKEND_BASE_URL must contain a credential-free host.'
assert_absent "$temporary/credential_url.log" 'embedded-secret'
assert_no_partial_outputs credential_url

run_failure insecure_url \
  SONUS_REQUIRE_REAL_CONFIG=false \
  SONUS_BACKEND_BASE_URL=http://backend.example.test \
  SONUS_SUPABASE_URL=https://project.supabase.co \
  SONUS_SUPABASE_ANON_KEY=sb_publishable_configured_fixture
assert_line "$temporary/insecure_url.log" 'SONUS_BACKEND_BASE_URL must use HTTPS for a distributable desktop build.'
assert_no_partial_outputs insecure_url

run_failure loopback_url \
  SONUS_REQUIRE_REAL_CONFIG=false \
  SONUS_BACKEND_BASE_URL=https://backend.example.test \
  SONUS_SUPABASE_URL=https://127.0.0.1:54321 \
  SONUS_SUPABASE_ANON_KEY=sb_publishable_configured_fixture
assert_line "$temporary/loopback_url.log" 'SONUS_SUPABASE_URL may not use a loopback host for a distributable desktop build.'
assert_no_partial_outputs loopback_url

run_failure secret_key \
  SONUS_REQUIRE_REAL_CONFIG=true \
  SONUS_BACKEND_BASE_URL=https://backend.example.test \
  SONUS_SUPABASE_URL=https://project.supabase.co \
  SONUS_SUPABASE_ANON_KEY=sb_secret_must_never_ship
assert_line "$temporary/secret_key.log" 'SONUS_SUPABASE_ANON_KEY must be a public publishable/anon key, never a secret or service-role key.'
assert_absent "$temporary/secret_key.log" 'sb_secret_must_never_ship'
assert_no_partial_outputs secret_key

run_failure invalid_boolean SONUS_REQUIRE_REAL_CONFIG=maybe
assert_line "$temporary/invalid_boolean.log" 'Expected a boolean flag, got an unsupported value.'
assert_no_partial_outputs invalid_boolean

echo "Desktop build configuration tests passed: $pass_count cases."
