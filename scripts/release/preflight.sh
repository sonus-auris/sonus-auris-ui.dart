#!/usr/bin/env bash
# Pre-release gate. Read-only: builds nothing, uploads nothing. Reports whether
# the project is ready to cut a store build, with a non-zero exit if a hard gate
# fails. Soft gates (compliance docs, signing) warn so you can run it early.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
fail=0; warn=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; fail=1; }
soft() { echo "  ! $*"; warn=1; }

echo "== Version =="
version_line="$(grep -E '^version:' pubspec.yaml || true)"
if [[ -n "$version_line" ]]; then printf '  %s\n' "$version_line"
else bad "pubspec.yaml version missing"; fi

echo "== Static analysis (hard gate) =="
if flutter analyze 2>&1 | tail -1 | grep -q "No issues found"; then ok "flutter analyze clean"
else bad "flutter analyze reported issues (run: flutter analyze)"; fi

echo "== Tests (hard gate) =="
if flutter test >/tmp/sa-preflight-test.log 2>&1; then ok "flutter test passed ($(grep -Eo '\+[0-9]+' /tmp/sa-preflight-test.log | tail -1) )"
else bad "flutter test failed (see /tmp/sa-preflight-test.log)"; fi

echo "== Android signing =="
if [[ -f android/key.properties && -f android/app/upload-keystore.jks ]]; then ok "upload keystore + key.properties present"
else soft "no upload keystore/key.properties — release .aab would be debug-signed (run android-generate-keystore.sh)"; fi

echo "== iOS export config =="
[[ -f ios/ExportOptions.plist ]] && ok "ios/ExportOptions.plist present" || soft "ios/ExportOptions.plist missing"
if grep -q ITSAppUsesNonExemptEncryption ios/Runner/Info.plist; then ok "export-compliance key set in Info.plist"
else soft "ITSAppUsesNonExemptEncryption missing (uploads will prompt) — see docs/compliance/EXPORT_COMPLIANCE.md"; fi

echo "== Release auth config =="
[[ -n "${SONUS_BACKEND_BASE_URL:-}" ]] && ok "SONUS_BACKEND_BASE_URL set" || soft "SONUS_BACKEND_BASE_URL missing — release builds will need manual backend config"
[[ -n "${SONUS_SUPABASE_URL:-}" ]] && ok "SONUS_SUPABASE_URL set" || soft "SONUS_SUPABASE_URL missing — sign-in form will show developer project fields"
[[ -n "${SONUS_SUPABASE_ANON_KEY:-}" ]] && ok "SONUS_SUPABASE_ANON_KEY set" || soft "SONUS_SUPABASE_ANON_KEY missing — sign-in form will show developer project fields"

echo "== Compliance artifacts (store gates) =="
for f in PRIVACY_POLICY ACCOUNT_DELETION DATA_SAFETY_play PRIVACY_LABELS_appstore PERMISSIONS_RATIONALE EXPORT_COMPLIANCE; do
  [[ -f "docs/compliance/$f.md" ]] && ok "docs/compliance/$f.md" || soft "missing docs/compliance/$f.md"
done

echo
if [[ $fail -ne 0 ]]; then echo "PREFLIGHT: FAIL (hard gate). Fix the ✗ items."; exit 1
elif [[ $warn -ne 0 ]]; then echo "PREFLIGHT: OK with warnings (!) — fine for a test build; resolve before production."; exit 0
else echo "PREFLIGHT: all green."; exit 0; fi
