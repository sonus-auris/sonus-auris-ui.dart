#!/usr/bin/env bash
# Verify the exact AAB package and signer before any Google Play edit is created.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

expected_package="${1:?usage: verify-android-publication.sh <package> <bundle>}"
bundle="${2:?usage: verify-android-publication.sh <package> <bundle>}"
keystore="${ANDROID_UPLOAD_KEYSTORE_PATH:-android/app/upload-keystore.jks}"

[[ -f "$bundle" && -s "$bundle" ]] || {
  echo "verify-android-publication: bundle is missing or empty: $bundle" >&2
  exit 1
}
[[ -f "$keystore" && -s "$keystore" ]] || {
  echo "verify-android-publication: upload keystore is missing or empty: $keystore" >&2
  exit 1
}
[[ -n "${KEY_ALIAS:-}" && -n "${STORE_PASSWORD:-}" ]] || {
  echo "verify-android-publication: KEY_ALIAS and STORE_PASSWORD are required" >&2
  exit 1
}

python3 scripts/release/check_android_package_contract.py \
  --expected "$expected_package" \
  --print-application-id >/dev/null

bundletool_version="1.18.3"
bundletool_sha256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
bundletool_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sonus-auris-bundletool"
bundletool_jar="$bundletool_dir/bundletool-all-$bundletool_version.jar"
mkdir -p "$bundletool_dir"

if [[ ! -f "$bundletool_jar" ]] ||
   ! printf '%s  %s\n' "$bundletool_sha256" "$bundletool_jar" | sha256sum --check --status; then
  curl --fail --location --silent --show-error \
    --retry 3 \
    --proto '=https' \
    --tlsv1.2 \
    "https://github.com/google/bundletool/releases/download/$bundletool_version/bundletool-all-$bundletool_version.jar" \
    --output "$bundletool_jar"
fi
printf '%s  %s\n' "$bundletool_sha256" "$bundletool_jar" | sha256sum --check --status || {
  echo "verify-android-publication: bundletool checksum mismatch" >&2
  exit 1
}

actual_package="$(
  java -jar "$bundletool_jar" dump manifest \
    --bundle="$bundle" \
    --xpath='/manifest/@package' |
    tr -d '[:space:]"'
)"
[[ -n "$actual_package" ]] || {
  echo "verify-android-publication: bundletool returned no package name" >&2
  exit 1
}
[[ "$actual_package" == "$expected_package" ]] || {
  echo "verify-android-publication: AAB package '$actual_package' differs from '$expected_package'" >&2
  exit 1
}

export LC_ALL=C
expected_fingerprint="$(
  keytool -list -v \
    -keystore "$keystore" \
    -alias "$KEY_ALIAS" \
    -storepass:env STORE_PASSWORD 2>/dev/null |
    awk -F': ' '/SHA256:/{gsub(/[[:space:]]/, "", $2); print toupper($2); exit}'
)"
actual_fingerprint="$(
  keytool -printcert -jarfile "$bundle" 2>/dev/null |
    awk -F': ' '/SHA256:/{gsub(/[[:space:]]/, "", $2); print toupper($2); exit}'
)"

[[ -n "$expected_fingerprint" && -n "$actual_fingerprint" ]] || {
  echo "verify-android-publication: could not read both SHA-256 certificate fingerprints" >&2
  exit 1
}
[[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
  echo "verify-android-publication: AAB signer does not match the configured upload key" >&2
  exit 1
}

printf 'Verified Android publication artifact: package=%s signer_sha256=%s\n' \
  "$actual_package" "$actual_fingerprint"
