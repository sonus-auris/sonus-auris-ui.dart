# Publishing follow-ups

Last reviewed: July 29, 2026.

The repository now contains the build, upload, installer-signing, notarization,
and R2 publication paths. The remaining blockers are account enrollment,
production credentials, store records/metadata, and physical-device acceptance.
These pages may ask an account owner to sign in again.

Local release verification on July 29 passed all 377 Flutter tests, static
analysis, the Android AAB build, unsigned iOS device build, Flutter macOS build,
Rust desktop release build, store screenshot OCR/dimension gate, backend tests,
and generated-interface tests. The live privacy/support/account-deletion pages
are reachable and the live privacy policy has no known placeholders. The
remaining hard preflight failures are a reachable production backend, protected
environment provisioning for the verified Sonus Supabase project, and Apple
signing access.

- [ ] Finish Apple Developer Program enrollment and billing:
  [Apple checkout](https://secure7.store.apple.com/shop/checkout?_s=Billing)
- [ ] Create or finish the Sonus Auris App Store Connect app record for
  `com.ores.audioDashcam`; accept current agreements, tax, and banking terms:
  [App Store Connect apps](https://appstoreconnect.apple.com/apps)
- [ ] Create an App Store Connect API key with the narrowest role that can upload
  builds. Retain the `.p8` in the protected GitHub environment only.
- [x] Google Play organization account verified and paid app record created on
  July 29, 2026 as **Sonus Auris - Audio Dashcam**, package
  `com.ores.sonus_auris`.
- [x] Canonical production Supabase project selected and dashboard-verified on
  July 29, 2026: organization `sonus-auris` (`ngixgitdtrbwnaimwsbb`), project
  `mckxblyvfzyoxpwvrnjm`, AWS `us-east-2`. Use
  `https://mckxblyvfzyoxpwvrnjm.supabase.co` plus the active publishable key
  named `default` in protected client-build environments. The hosted Auth
  settings endpoint accepted that key on July 29, 2026. Retrieve the key from
  the dashboard; do not commit it. The currently connected project-scoped
  Supabase tool reports `vgzyyfhnendriyrhakkp`, which is not the project in the
  Sonus Auris organization and must not be used for Sonus migrations,
  configuration, or key retrieval. Never place service-role or secret keys in a
  client build.
- [ ] In the selected Supabase project, set the passwordless email template to
  display `{{ .Token }}` as the primary six-digit sign-in code. Retain the
  PKCE-bound link only if a fallback is desired. Apply
  `20260729010000_mandatory_mfa.sql`, enable TOTP and/or phone MFA, then prove
  that AAL1 is denied and AAL2 succeeds against the hosted project.
- [ ] Apply `20260729020000_lifetime_entitlements.sql` and deploy the trusted
  Play-license/account-cohort grant before the first paid production release.
  Every verified paid-app purchaser must receive a non-expiring `lifetime`
  entitlement; subscription cancellation or expiration processing must never
  overwrite it. Prove reinstall, account recovery, and device replacement with
  a grandfathered test account before any future subscription transition.
- [ ] Set up a Cloudflare R2 bucket for Sonus Auris, configure its S3-compatible
  endpoint and scoped credentials in the backend secret store, and define the
  production retention/lifecycle policy.
- [ ] Register production OAuth apps for Google Drive (`drive.file`), Microsoft
  OneDrive (AppFolder), and Dropbox (App Folder plus
  `files.content.write`). Register both exact hosted callback URLs
  (`/oauth/callback` for mobile/macOS and `/oauth/manual-callback` for
  Windows/Linux) with all three providers, place each client ID/secret and the
  cloud-token encryption key in the backend secret store, and pin both callbacks in
  `SOUND_RECORDER_OAUTH_REDIRECT_ALLOWLIST`.
- [ ] Enable the production iCloud container and entitlements for the iOS and
  macOS signing profiles, then verify linking from the app's Connections tab on
  a signed Apple device. The unsigned macOS build uses
  `Runner/Release.entitlements`; the signed iCloud-capable distribution profile
  must use `macos/Runner/Store.entitlements`.
=======
- [ ] Create or finish the Sonus Auris App Store Connect app record for
  `com.ores.audioDashcam`; accept current agreements, tax, and banking terms.
- [ ] Finish Google Play developer-account registration and create the app record
  for `com.ores.audio_dashcam`.
- [ ] Create the Google Play API service account, link it in Play Console, and
  grant only the Sonus Auris app/track permissions required for publication.
- [ ] Create an App Store Connect API key with the narrowest role that can upload
  builds. Retain the `.p8` in the protected GitHub environment only.
- [ ] Confirm the production Supabase project uses asymmetric signing keys/JWKS,
  email confirmation, redirect allow-lists, short session limits, and RLS on all
  exposed tables. Retain service-role credentials only in server secret stores.
- [ ] Create the Cloudflare R2 release bucket, scoped API token, custom download
  domain, and cache rules. The public site must not use the rate-limited `r2.dev`
  development URL.
>>>>>>> origin/main

## Protected GitHub environments

<<<<<<< HEAD
- [ ] Populate the existing protected GitHub `mobile-production` environment
  with the production backend/Supabase values plus Android and Apple signing
  secrets documented in `docs/mobile-ci.md`. As checked on July 25, 2026, the
  environment exists but has no configured secrets or variables.
- [ ] Point `SONUS_BACKEND_BASE_URL` at the Sonus-owned cluster hostname after
  `api.sonusauris.app` DNS, TLS, and gateway routing are declared through Argo.
  The hostname did not resolve publicly when checked on July 25, 2026.
- [ ] Verify the Argo-managed backend readiness endpoint from outside the
  cluster, then exercise sign-in, consent, upload, deletion, purchases, and
  client telemetry against production Supabase from a physical Android device
  and iPhone.
- [ ] Run the signed Android workflow, upload the AAB to Play internal testing,
  install it on the physical Android device, and complete a background-recording
  battery/network-loss test.
- [ ] Run the signed iOS workflow, upload the IPA to TestFlight, install it on
  the physical iPhone, and complete lock-screen/background-audio and permission
  review tests.
- [ ] Review the GitHub Linux/macOS/Windows desktop artifacts; configure macOS
  signing/notarization and Windows signing/installers before distributing them.
  The Rust desktop now links Google Drive/OneDrive/Dropbox and has an explicit,
  default-off encrypted backup path for finalized WAVs using the same SAC1
  format as Flutter. Its CI matrix includes the native OS credential-vault
  dependencies; exercise each packaged build against a real provider before
  release.
- [ ] Upgrade or replace Flutter plugins that still apply the legacy Kotlin
  Gradle plugin or lack Apple Swift Package Manager support before Flutter turns
  the current build warnings into errors; also track the StoreKit 1 deprecation
  warnings emitted by `in_app_purchase_storekit` on macOS 15.
- [ ] Promote the Flutter web console only by updating its exact source pin in
  `~/codes/ores/k8s-cluster/remote/argocd/dd-next-runtime` and allowing Argo to
  reconcile it. Run both Puppeteer and Playwright against the deployed URL.
- [ ] Complete the move to `sonus-auris-monorepo` as the canonical source for
  every Argo Sonus workload. The console build now consumes and verifies the
  console revision from the node's pinned monorepo checkout without a personal
  token. Next, move the Argo application resources and backend build source into
  the monorepo-owned path after the integration workflow is green and every
  nested revision is pushed. Prefer repository deploy keys or a short-lived
  GitHub App token for any remaining private fetch, verify backend and console
  health, and then retire the temporary `k8s-cluster` deployment definitions.

After the accounts are active, create the store records with the existing
identifiers (`com.ores.audioDashcam` for iOS and
`com.ores.sonus_auris` for Android), enroll the signing keys, upload first to
TestFlight and Play internal testing, and complete the store privacy forms.
=======
- [ ] Create `mobile-production`, require reviewer approval, restrict deployment
  to `main`, and add the mobile values documented in `docs/mobile-ci.md`.
- [ ] Create `desktop-production` with the same branch/reviewer controls; add the
  Windows signing, macOS Developer ID/notarization, R2, and public client values.
- [ ] Keep all release workflows at `contents: read`, disable persisted checkout
  credentials, and rotate any credential that has ever appeared in logs or a
  developer-generated file.

## Product and compliance readiness

- [ ] Replace placeholder legal entity/contact/postal values on the marketing
  privacy and account-deletion pages before either store submission.
- [ ] Complete App Store privacy labels and Google Play Data safety from the
  actual shipped behavior: linked email/user/device identifiers, audio,
  optional precise/coarse location, diagnostics, retention, deletion, and no
  tracking.
- [ ] Prepare Apple review notes explaining user-initiated continuous recording,
  visible recording state, background audio behavior, account deletion, IAP,
  optional location/Bluetooth/Wi-Fi features, and non-diagnostic acoustic labels.
- [ ] Prepare Play declarations for microphone foreground service, exact alarms,
  background behavior, location/nearby-device access, subscriptions, and account
  deletion. Remove any permission not exercised by the submitted build.
- [ ] Supply screenshots, support URL, privacy URL, age/category answers,
  descriptions, keywords, and tester instructions in both stores.

## Release acceptance

- [ ] Point `SONUS_BACKEND_BASE_URL` at the Sonus-owned production gateway after
  DNS, TLS, and Argo routing are ready.
- [ ] Exercise sign-in, consent, RLS isolation, recording, upload/retry,
  retention, permanent save, purchase/restore, export, and account deletion
  against production on physical Android and iPhone hardware.
- [ ] Build Android with an unused versionCode. Publish first to Play internal
  testing through `.github/workflows/android-release.yml`.
- [ ] Build iOS with an unused CFBundleVersion. Upload first for TestFlight
  processing through `.github/workflows/ios-build.yml`.
- [ ] Verify background recording under lock, interruption, reboot, battery
  pressure, network loss/recovery, and force-quit constraints on real devices.
- [ ] Build the three signed desktop installers with
  `.github/workflows/desktop-release.yml`; verify clean install, signature,
  notarization, upgrade, launch-at-login, and uninstall before R2 publication.
- [ ] Set the marketing deployment values from `.env.example` in
  `sonus-auris-site.web` after the store listings and R2 custom domain are live.
- [ ] Promote beyond internal/TestFlight only after reviewing telemetry and
  confirming that logs contain no tokens, audio content, secrets, or user text.

## Repository and GitOps follow-ups

- [ ] Keep `sonus-auris-monorepo` as the canonical integration source and update
  pinned nested revisions only after each child PR is green and merged.
- [ ] Move any remaining temporary deployment definitions out of personal
  `k8s-cluster` paths into Sonus-owned GitOps repositories, using deploy keys or
  short-lived GitHub App credentials for private source fetches.
- [ ] Upgrade Flutter plugins that still depend on legacy Kotlin Gradle behavior,
  lack Apple Swift Package Manager support, or retain StoreKit 1 APIs before a
  future Flutter/Xcode release turns warnings into build failures.

The permanent identifiers remain `com.ores.audioDashcam` for iOS and
`com.ores.audio_dashcam` for Android. Do not change either after the first store
upload.
>>>>>>> origin/main
