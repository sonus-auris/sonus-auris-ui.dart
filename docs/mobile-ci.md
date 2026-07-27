# Mobile and desktop CI/release plan

Last reviewed: July 27, 2026.

## Runner matrix

| Target | Runner | Automatic evidence | Protected release path |
|---|---|---|---|
| Android | GitHub Linux plus the Kubernetes build server | analyze, unit tests, emulator tests, debug APK | signed AAB, optional Play Developer API commit |
| iOS | GitHub-hosted macOS 15 | unsigned release compile using the current Xcode/iOS SDK | signed IPA, optional App Store Connect upload |
| Linux desktop | GitHub Linux plus an on-cluster fixed build profile | release bundle from `lib/main_desktop.dart` | `.deb` installer |
| macOS desktop | GitHub-hosted macOS 15 | unsigned `.app` from `lib/main_desktop.dart` | Developer ID signed, notarized, stapled `.dmg` |
| Windows desktop | GitHub-hosted Windows | unsigned release directory from `lib/main_desktop.dart` | Authenticode-signed Inno Setup `.exe` |

The Kubernetes node is intentionally not an Apple or Windows builder. Xcode is
licensed and available only on macOS; Windows desktop must be compiled on
Windows. GitHub-hosted native runners provide reproducible clean machines now;
dedicated native self-hosted workers can replace them later without changing the
workflow contract.

## Protected mobile release inputs

Create a GitHub environment named `mobile-production`, require reviewer approval,
restrict it to `main`, and add only the following narrowly scoped values.

Shared client configuration:

- `SONUS_BACKEND_BASE_URL`
- `SONUS_SUPABASE_URL`
- `SONUS_SUPABASE_ANON_KEY` (publishable/anon client key, never service-role)

Android signing and Play upload:

- `ANDROID_UPLOAD_KEYSTORE_BASE64`
- `ANDROID_UPLOAD_KEYSTORE_PASSWORD`
- `ANDROID_UPLOAD_KEY_ALIAS`
- `ANDROID_UPLOAD_KEY_PASSWORD`
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` — service account with only the required
  app/track permissions in Play Console

Apple signing and App Store Connect upload:

- `IOS_DEVELOPMENT_TEAM`
- `IOS_DIST_CERT_P12_BASE64`
- `IOS_DIST_CERT_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`

The Android and iOS workflows always create reviewable signed artifacts first.
Publication is a separate boolean dispatch input and remains behind the protected
environment. Android defaults to the internal track. The iOS upload only sends a
build to App Store Connect for processing/TestFlight; it does not submit an app
version for review or release it to customers.

## Protected desktop release inputs

Create a second `desktop-production` environment, also reviewer-gated and
restricted to `main`.

Shared client configuration:

- `SONUS_BACKEND_BASE_URL`
- `SONUS_SUPABASE_URL`
- `SONUS_SUPABASE_ANON_KEY`

Windows Authenticode:

- `WINDOWS_SIGNING_PFX_BASE64`
- `WINDOWS_SIGNING_PFX_PASSWORD`

macOS Developer ID and notarization:

- `MACOS_DEVELOPER_ID_P12_BASE64`
- `MACOS_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_API_KEY_P8_BASE64`

Cloudflare R2 publication:

- `R2_ENDPOINT_URL` — `https://<account-id>.r2.cloudflarestorage.com`
- `R2_BUCKET`
- `R2_PUBLIC_BASE_URL` — production custom domain such as
  `https://downloads.sonusauris.app`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`

Use an R2 token scoped to object read/write for this one bucket. The workflow
publishes immutable objects under `releases/<version>/`, then replaces the
`latest/` aliases and `latest.json` with `Cache-Control: no-store`. The marketing
site links directly to the R2 custom domain. The Rust backend may return release
metadata or an HTTP redirect, but it must not proxy public installer bytes.

## Release acceptance sequence

1. Merge a green version bump to `main` and confirm unit, emulator, unsigned
   iOS, desktop, and release-tooling jobs.
2. Confirm the Argo-managed Kubernetes backend is ready and production Supabase
   passes auth/RLS isolation smoke tests.
3. Dispatch Android with `publish_to_play=false`, install the signed AAB through
   local/internal tooling, and test a physical Android device across Wi-Fi loss,
   reboot, background recording, permissions, purchase restore, and deletion.
4. Re-dispatch the accepted build number with `publish_to_play=true` and the
   `internal` track. Promote beyond internal only after the cohort passes.
5. Dispatch iOS with `signed_ipa=true` and `upload_to_app_store=false`; install
   and validate on a physical iPhone. Then upload the same accepted version/build
   to App Store Connect for TestFlight processing.
6. Review client telemetry and traces while testing. Redact secrets, audio
   content, tokens, and user-entered text; validate retention and RLS.
7. Build signed desktop installers with `publish_to_r2=false`, verify signatures,
   notarization, installation, upgrade, and uninstall on clean machines, then
   publish the same version to R2.
8. Only after internal cohorts pass, complete store privacy forms and move to
   closed/external testing. Production promotion remains a human decision.

## GitOps boundary

The app consumes the backend; it does not deploy it. The backend lives in the
Sonus Auris GitOps definitions and all workload, routing, secret-reference, and
revision changes are reviewed there and reconciled by Argo CD. CI builds and
publishes client artifacts but must not perform a direct live-cluster apply.

## Toolchain watch list

Current builds are green but emit upstream migration warnings. Several plugins
still apply the legacy Kotlin Gradle plugin, several Apple plugins have not
adopted Swift Package Manager, and `in_app_purchase_storekit` uses StoreKit 1
APIs deprecated on macOS 15. Track these on dependency upgrades so a future
Flutter/Xcode release does not turn a warning into a release-day failure.
