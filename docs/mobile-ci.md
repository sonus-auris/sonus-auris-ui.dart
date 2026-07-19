# Mobile and desktop CI/release plan

Last reviewed: July 18, 2026.

## Runner matrix

| Target | Runner | Automatic evidence |
|---|---|---|
| Android | GitHub Linux plus the Kubernetes build server | analyze, unit tests, emulator tests, debug APK |
| iOS | GitHub-hosted macOS 15 | unsigned release compile using the current Xcode/iOS SDK |
| Linux desktop | GitHub Linux plus an on-cluster fixed build profile | release bundle from `lib/main_desktop.dart` |
| macOS desktop | GitHub-hosted macOS 15 | unsigned `.app` from `lib/main_desktop.dart` |
| Windows desktop | GitHub-hosted Windows | unsigned release directory from `lib/main_desktop.dart` |

The Kubernetes node is intentionally not an Apple or Windows builder. Xcode is
licensed and available only on macOS; Windows desktop must be compiled on
Windows. GitHub-hosted native runners provide reproducible clean machines now;
dedicated native self-hosted workers can replace them later without changing the
workflow contract.

## Protected release inputs

Create a GitHub environment named `mobile-production`, require reviewer approval,
and add only the following narrowly scoped values.

Shared client configuration:

- `SONUS_BACKEND_BASE_URL`
- `SONUS_SUPABASE_URL`
- `SONUS_SUPABASE_ANON_KEY` (publishable/anon client key, never service-role)

Android signing:

- `ANDROID_UPLOAD_KEYSTORE_BASE64`
- `ANDROID_UPLOAD_KEYSTORE_PASSWORD`
- `ANDROID_UPLOAD_KEY_ALIAS`
- `ANDROID_UPLOAD_KEY_PASSWORD`

Apple signing:

- `IOS_DEVELOPMENT_TEAM`
- `IOS_DIST_CERT_P12_BASE64`
- `IOS_DIST_CERT_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`

The workflows materialize signing files only for the job, build through the
repository release scripts, emit SHA-256 evidence, and remove the temporary
files. They do not store a Supabase service-role key and do not publish to a
store automatically.

## Release acceptance sequence

1. Merge a green version bump to `main` and confirm unit, emulator, unsigned
   iOS, and desktop jobs.
2. Confirm the Argo-managed Kubernetes backend is ready and the production
   Supabase project passes auth/RLS smoke tests.
3. Manually dispatch Android signing, download/check the AAB, upload to Play
   internal testing, and test on a physical device across Wi-Fi loss/recovery,
   reboot, background recording, permissions, and account deletion.
4. Manually dispatch iOS signing, download/check the IPA, upload to TestFlight,
   and test on a physical device across lock screen, interruption, permissions,
   networking, purchase restore, and deletion.
5. Review client telemetry and traces in Supabase while testing. Redact secrets,
   audio content, tokens, and user-entered text; validate retention and RLS.
6. Only after both internal cohorts pass, complete store privacy forms and move
   to closed/external testing. Production promotion remains a human decision.

## GitOps boundary

The app consumes the backend; it does not deploy it. The backend lives in
`~/codes/ores/k8s-cluster` and all workload, routing, secret-reference, and
revision changes are committed there and reconciled by Argo CD. CI can build and
test artifacts, but it must not perform a direct live-cluster apply.

## Toolchain watch list

Current builds are green but emit upstream migration warnings. Several plugins
still apply the legacy Kotlin Gradle plugin, several Apple plugins have not
adopted Swift Package Manager, and `in_app_purchase_storekit` uses StoreKit 1
APIs deprecated on macOS 15. Track these on dependency upgrades so a future
Flutter/Xcode release does not turn a warning into a release-day failure.
