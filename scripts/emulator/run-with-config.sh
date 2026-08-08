#!/usr/bin/env bash
# Launch the app on a simulator/emulator with real Supabase and backend config.
#
# Why this exists: AppConfig reads SONUS_SUPABASE_URL and SONUS_SUPABASE_ANON_KEY
# through `String.fromEnvironment`, which is resolved at **compile time**. A bare
# `flutter run` therefore produces a binary in which both are the empty string,
# `AppConfig.hasSupabaseAuthConfig` is false, and the app reports that it cannot
# reach Supabase — even though the credentials are correctly stored in
# sonus-auris.infra. The release scripts in scripts/release/ already convert
# these variables into --dart-define; this is the same contract for local runs.
#
#   scripts/emulator/run-with-config.sh                 # dev env, first device
#   scripts/emulator/run-with-config.sh --env prod
#   scripts/emulator/run-with-config.sh --dry-run       # show config, launch nothing
#   scripts/emulator/run-with-config.sh -- -d emulator-5554
#
# Everything after `--` is passed through to `flutter run`.
#
# Networking note. An Android emulator reaches the host loopback at 10.0.2.8...
# specifically 10.0.2.2, an iOS simulator uses localhost, and a physical handset
# can reach neither. If SONUS_BACKEND_BASE_URL points at localhost this script
# rewrites it to 10.0.2.2 for Android. The rewrite is a convenience for the
# simplest case — for anything beyond one machine, prefer a Cloudflare tunnel
# (`just tunnel-up dev` in sonus-auris.infra), whose hostname is the same string
# on every device including real hardware.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
infra_dir="${SONUS_INFRA_DIR:-$repo_root/../sonus-auris.infra}"
env_name="dev"
dry_run=0
platform=""
flutter_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_name="${2:?--env needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --platform) platform="${2:?--platform needs a value}"; shift 2 ;;
    --) shift; flutter_args+=("$@"); break ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) flutter_args+=("$1"); shift ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# --- resolve configuration -------------------------------------------------
# Prefer whatever the operator has already activated (`just use <env>` leaves a
# .env symlink); fall back to decrypting the named environment directly so this
# works on a clean checkout without mutating infra state.
env_source=""
active_env=""
if [[ -f "$infra_dir/.env" ]]; then
  # `just use <env>` points .env at env/dec/<env>.env. Report the environment
  # that is actually being read, not the one that was asked for — they differ
  # whenever an operator has a different env active, and silently compiling
  # prod credentials into a build that was asked for dev is exactly the kind of
  # mistake this script should make impossible to miss.
  active_env="$(basename "$(readlink "$infra_dir/.env" 2>/dev/null || echo "$infra_dir/.env")" .env)"
  env_source="$infra_dir/.env -> ${active_env}.env"
  if [[ -n "$active_env" && "$active_env" != "$env_name" ]]; then
    echo "warning: requested --env $env_name, but $infra_dir/.env is active and points at $active_env." >&2
    echo "         using $active_env. Run 'just use $env_name' in the infra repo to switch." >&2
    env_name="$active_env"
  fi
  set -a
  # shellcheck disable=SC1091
  source "$infra_dir/.env"
  set +a
elif [[ -f "$infra_dir/env/enc/$env_name.env.enc" ]]; then
  command -v sops >/dev/null 2>&1 || die "sops not found — run 'nix develop' in $infra_dir"
  # sops resolves its age identity from os.UserConfigDir(), which on macOS is
  # ~/Library/Application Support — not ~/.config. Point it at the documented
  # location when the caller has not.
  if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$HOME/.config/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  fi
  env_source="$infra_dir/env/enc/$env_name.env.enc (decrypted in memory)"
  decrypted="$(sops decrypt --input-type dotenv --output-type dotenv \
    "$infra_dir/env/enc/$env_name.env.enc")" || die "could not decrypt $env_name"
  set -a
  # shellcheck disable=SC1090
  source /dev/stdin <<<"$decrypted"
  set +a
  unset decrypted
else
  die "no config found: neither $infra_dir/.env nor env/enc/$env_name.env.enc"
fi

# --- required by AppConfig -------------------------------------------------
missing=()
for name in SONUS_SUPABASE_URL SONUS_SUPABASE_ANON_KEY; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
if (( ${#missing[@]} )); then
  die "missing from $env_source: ${missing[*]}
These live in sonus-auris.infra. Check with: cd $infra_dir && just keys $env_name"
fi

# --- Android loopback rewrite ----------------------------------------------
backend="${SONUS_BACKEND_BASE_URL:-}"
if [[ -n "$backend" && "$platform" == "android" ]]; then
  rewritten="${backend//localhost/10.0.2.2}"
  rewritten="${rewritten//127.0.0.1/10.0.2.2}"
  if [[ "$rewritten" != "$backend" ]]; then
    echo "note: rewrote backend loopback for the Android emulator"
    backend="$rewritten"
  fi
fi

# --- assemble --dart-define ------------------------------------------------
# Same contract as scripts/release/*: every SONUS_* the app reads, and only
# those. The anon key is client-safe by design; a service-role or secret key
# must never appear here — it would be extractable from the shipped binary.
dart_defines=()
# Note the explicit `if`: a bare `[[ ... ]] && ...` returns non-zero when the
# value is empty, which under `set -e` exits the script instead of skipping.
add_define() {
  if [[ -n "${2:-}" ]]; then
    dart_defines+=(--dart-define="$1=$2")
  fi
}

# Anything compiled in here is extractable from the shipped binary, so verify
# what the value *is* rather than trusting the variable it came from. The
# plausible mistake is not naming a define after a secret — it is pasting a
# service-role or secret key into SONUS_SUPABASE_ANON_KEY.
assert_client_safe() {
  local name="$1" value="$2"
  case "$value" in
    sb_secret_*) die "$name holds a Supabase *secret* key. Only the anon/publishable key may be compiled into the client." ;;
  esac
  # A Supabase JWT carries its role in the payload; decode and check it.
  if [[ "$value" == eyJ*.*.* ]]; then
    local payload role
    payload="${value#*.}"; payload="${payload%%.*}"
    while (( ${#payload} % 4 )); do payload+="="; done
    role="$(printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null \
            | sed -n 's/.*"role":"\([^"]*\)".*/\1/p')" || true
    if [[ "$role" == "service_role" ]]; then
      die "$name holds a service_role JWT, which bypasses row-level security. Use the anon key."
    fi
  fi
  return 0
}

assert_client_safe SONUS_SUPABASE_ANON_KEY "$SONUS_SUPABASE_ANON_KEY"

add_define SONUS_SUPABASE_URL "$SONUS_SUPABASE_URL"
add_define SONUS_SUPABASE_ANON_KEY "$SONUS_SUPABASE_ANON_KEY"
add_define SONUS_BACKEND_BASE_URL "$backend"

redact() { local v="$1"; (( ${#v} > 12 )) && echo "${v:0:6}…${v: -4} (${#v} chars)" || echo "set"; }
echo "config source : $env_source"
echo "environment   : $env_name"
echo "supabase url  : $SONUS_SUPABASE_URL"
echo "supabase anon : $(redact "$SONUS_SUPABASE_ANON_KEY")"
echo "backend url   : ${backend:-<unset>}"
echo "dart-defines  : ${#dart_defines[@]}"

if (( dry_run )); then
  echo
  echo "would run: flutter run ${dart_defines[*]/#--dart-define=SONUS_SUPABASE_ANON_KEY=*/--dart-define=SONUS_SUPABASE_ANON_KEY=<redacted>} ${flutter_args[*]:-}"
  exit 0
fi

cd "$repo_root"
exec flutter run "${dart_defines[@]}" ${flutter_args[@]+"${flutter_args[@]}"}
