#!/usr/bin/env bash
# Resolve compile-time account endpoints for desktop builds without making
# ordinary CI depend on live services. Any artifact publication path must opt
# into strict mode and provide real configuration.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV must name the environment file to update}"

readonly compile_backend_url='http://127.0.0.1:8126'
readonly compile_supabase_url='http://127.0.0.1:54321'
readonly compile_supabase_key='sb_publishable_compile_only'
readonly config_names=(
  SONUS_BACKEND_BASE_URL
  SONUS_SUPABASE_URL
  SONUS_SUPABASE_ANON_KEY
)

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off|'') return 1 ;;
    *)
      echo "Expected a boolean flag, got an unsupported value." >&2
      return 2
      ;;
  esac
}

reject_multiline() {
  local name="$1"
  local value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "$name may not contain line breaks." >&2
    return 1
  fi
}

validate_http_url() {
  local name="$1"
  local value="$2"
  reject_multiline "$name" "$value"
  if [[ ! "$value" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "$name must be an absolute http(s) URL." >&2
    return 1
  fi
  if [[ "$value" == *'?'* || "$value" == *'#'* ]]; then
    echo "$name may not contain a query string or fragment." >&2
    return 1
  fi
  local authority="${value#*://}"
  authority="${authority%%/*}"
  if [[ -z "$authority" || "$authority" == *'@'* ]]; then
    echo "$name must contain a credential-free host." >&2
    return 1
  fi
}

validate_publishable_key() {
  local value="$1"
  reject_multiline SONUS_SUPABASE_ANON_KEY "$value"
  if [[ -z "$value" ]]; then
    echo "SONUS_SUPABASE_ANON_KEY must not be empty." >&2
    return 1
  fi
  if [[ "$mode" != 'compile-only' && "$value" == "$compile_supabase_key" ]]; then
    echo "SONUS_SUPABASE_ANON_KEY may use the compile-only sentinel only in compile-only mode." >&2
    return 1
  fi
}

append_environment() {
  local name="$1"
  local value="$2"
  reject_multiline "$name" "$value"
  printf '%s=%s\n' "$name" "$value" >> "$GITHUB_ENV"
}

strict=false
if is_true "${SONUS_REQUIRE_REAL_CONFIG:-false}"; then
  strict=true
else
  status=$?
  if [[ $status -eq 2 ]]; then
    exit "$status"
  fi
fi

missing=()
for name in "${config_names[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
done

if $strict && ((${#missing[@]} > 0)); then
  printf 'Publishing requires real desktop build configuration; missing:' >&2
  printf ' %s' "${missing[@]}" >&2
  printf '\n' >&2
  exit 1
fi

mode='configured'
if ((${#missing[@]} > 0)); then
  # Never build a mixed real/fallback configuration. A partially configured
  # client could contact a live service with the wrong companion endpoint or
  # key. The compile-only mode is deliberately wholly inert.
  mode='compile-only'
  SONUS_BACKEND_BASE_URL="$compile_backend_url"
  SONUS_SUPABASE_URL="$compile_supabase_url"
  SONUS_SUPABASE_ANON_KEY="$compile_supabase_key"
fi
if $strict; then
  mode='publish'
fi

validate_http_url SONUS_BACKEND_BASE_URL "$SONUS_BACKEND_BASE_URL"
validate_http_url SONUS_SUPABASE_URL "$SONUS_SUPABASE_URL"
validate_publishable_key "$SONUS_SUPABASE_ANON_KEY"

# All validation is complete before the first write, so a failure never leaves
# a partially resolved environment for later workflow steps.
append_environment SONUS_BACKEND_BASE_URL "$SONUS_BACKEND_BASE_URL"
append_environment SONUS_SUPABASE_URL "$SONUS_SUPABASE_URL"
append_environment SONUS_SUPABASE_ANON_KEY "$SONUS_SUPABASE_ANON_KEY"
append_environment SONUS_DESKTOP_BUILD_CONFIG_MODE "$mode"

case "$mode" in
  compile-only)
    echo "Desktop build configuration: compile-only placeholders; distributable artifact upload is disabled."
    ;;
  configured)
    echo "Desktop build configuration: repository-provided values; artifacts may be retained but are not being published."
    ;;
  publish)
    echo "Desktop build configuration: protected publication mode with all required values present."
    ;;
esac
