#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
web_output="$repo_root/build/web"
apk="$repo_root/build/app/outputs/flutter-apk/app-release.apk"

flutter build web --release --no-pub
ALLOW_DEBUG_SIGNED_RELEASE=1 flutter build apk --release --no-pub

for marker in '424242' '/auth/test/supabase/session' '/auth/test/supabase/sms-hook'; do
  if LC_ALL=C grep -R -aFq -- "$marker" "$web_output"; then
    echo "release web bundle contains test-auth marker: $marker" >&2
    exit 1
  fi
  if (
    set +o pipefail
    unzip -p "$apk" | LC_ALL=C grep -aFq -- "$marker"
  ); then
    echo "release Android bundle contains test-auth marker: $marker" >&2
    exit 1
  fi
done

echo "test-auth code and route are absent from release web and Android artifacts"
