#!/usr/bin/env bash
# Create the Android **upload keystore** and a matching android/key.properties.
#
# With Play App Signing (recommended, enrol once in the Play Console), Google
# holds the real app-signing key; THIS key only signs your uploads and can be
# reset if lost. Keep it private anyway: it never gets committed (see
# android/.gitignore additions / .gitignore at repo root).
#
#   android-generate-keystore.sh            # interactive (prompts for passwords)
#   KEY_ALIAS=upload STORE_PASS=... KEY_PASS=... android-generate-keystore.sh --batch
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
android_dir="$repo_root/android"
keystore="$android_dir/app/upload-keystore.jks"
props="$android_dir/key.properties"
alias="${KEY_ALIAS:-upload}"

command -v keytool >/dev/null || { echo "keytool not found — install a JDK first." >&2; exit 1; }

if [[ -f "$keystore" ]]; then
  echo "Refusing to overwrite existing keystore: $keystore" >&2
  echo "Losing/replacing an upload key is recoverable via Play App Signing, but do this deliberately." >&2
  exit 1
fi

extra=()
if [[ "${1:-}" == "--batch" ]]; then
  : "${STORE_PASS:?set STORE_PASS for --batch}"; : "${KEY_PASS:?set KEY_PASS for --batch}"
  extra=(-storepass "$STORE_PASS" -keypass "$KEY_PASS" \
         -dname "CN=Sonus Auris, O=ORES, C=US")
fi

keytool -genkeypair -v \
  -keystore "$keystore" \
  -alias "$alias" \
  -keyalg RSA -keysize 2048 -validity 10000 \
  "${extra[@]}"

# key.properties is read by android/app/build.gradle.kts. It holds secrets, so
# it is gitignored. storeFile is relative to the android/app module dir.
cat > "$props" <<EOF
storeFile=upload-keystore.jks
keyAlias=${alias}
# Fill these in (or they were set non-interactively). NEVER commit this file.
storePassword=${STORE_PASS:-CHANGE_ME}
keyPassword=${KEY_PASS:-CHANGE_ME}
EOF

echo
echo "Created: $keystore"
echo "Wrote:   $props  (gitignored — contains passwords)"
echo "Next: enrol this upload key in Play App Signing when you create the Play Console app."
