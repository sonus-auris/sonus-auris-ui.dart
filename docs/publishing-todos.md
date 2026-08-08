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
- [ ] Create the Google Play API service account, link it in Play Console, and
  grant only the Sonus Auris app/track permissions required for publication.
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
  - **Required invariant: Auth → Email OTP length must be `6`.** The client
    rejects any other length: `supabase_auth_form.dart` requires
    `code.length == 6` and the input field caps at six characters. The project
    was configured for 8 on August 8, 2026, which silently blocked *every*
    sign-in — the emailed code simply never validated, with no server-side
    error to notice. Corrected to 6 the same day via the Management API
    (`PATCH /v1/projects/<ref>/config/auth {"mailer_otp_length":6}`); note that
    only an account-scoped Management PAT (`sbp_…`) can read or set this, so the
    service-role and publishable keys give no visibility into it. Re-check this
    value after any project restore or auth reconfiguration, or change the app
    to accept the configured length instead (DEN-3126).
  - AAL2 was proven end to end against the hosted project on August 8, 2026:
    six-digit email OTP → MFA gate → TOTP enrollment → verification →
    `aal2` with `amr` `[totp, otp]`, confirmed in-app and server-side
    (`admin/users/<id>/factors` reported `totp` `verified`). A password-grant
    token (`aal1`, `amr` `[password]`) is correctly refused by the backend, as
    is an unauthenticated device registration.
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
- [ ] Confirm the production Supabase project uses asymmetric signing keys/JWKS,
  email confirmation, redirect allow-lists, short session limits, and RLS on all
  exposed tables. Retain service-role credentials only in server secret stores.
- [ ] Create the Cloudflare R2 release bucket, scoped API token, custom download
  domain, and cache rules. The public site must not use the rate-limited `r2.dev`
  development URL.

## Protected GitHub environments

- [ ] Populate the protected GitHub `mobile-production` environment (require
  reviewer approval, restrict deployment to `main`) with the production
  backend/Supabase values plus Android and Apple signing secrets documented in
  `docs/mobile-ci.md`. As checked on July 25, 2026, the environment exists but
  has no configured secrets or variables.
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
  `api.sonusauris.app` DNS, TLS, and Argo routing are ready. The hostname did
  not resolve publicly when checked on July 25, 2026.
- [ ] Verify the Argo-managed backend readiness endpoint from outside the
  cluster, then exercise sign-in, consent, RLS isolation, recording,
  upload/retry, retention, permanent save, purchase/restore, export, client
  telemetry, and account deletion against production on physical Android and
  iPhone hardware.
- [ ] Build Android with an unused versionCode. Publish first to Play internal
  testing through `.github/workflows/android-release.yml`, install it on the
  physical Android device, and complete a background-recording
  battery/network-loss test.
- [ ] Build iOS with an unused CFBundleVersion. Upload first for TestFlight
  processing through `.github/workflows/ios-build.yml`, install it on the
  physical iPhone, and complete lock-screen/background-audio and permission
  review tests.
- [ ] Verify background recording under lock, interruption, reboot, battery
  pressure, network loss/recovery, and force-quit constraints on real devices.
- [ ] Build the three signed desktop installers with
  `.github/workflows/desktop-release.yml`; verify clean install, signature,
  notarization, upgrade, launch-at-login, and uninstall before R2 publication.
- [ ] Review the GitHub Linux/macOS/Windows desktop artifacts; configure macOS
  signing/notarization and Windows signing/installers before distributing them.
  The Rust desktop now links Google Drive/OneDrive/Dropbox and has an explicit,
  default-off encrypted backup path for finalized WAVs using the same SAC1
  format as Flutter. Its CI matrix includes the native OS credential-vault
  dependencies; exercise each packaged build against a real provider before
  release.
- [ ] Set the marketing deployment values from `.env.example` in
  `sonus-auris-site.web` after the store listings and R2 custom domain are live.
- [ ] Promote beyond internal/TestFlight only after reviewing telemetry and
  confirming that logs contain no tokens, audio content, secrets, or user text.

## Repository and GitOps follow-ups

- [ ] Keep `sonus-auris-monorepo` as the canonical integration source and update
  pinned nested revisions only after each child PR is green and merged. The
  console build now consumes and verifies the console revision from the node's
  pinned monorepo checkout without a personal token. Next, move the Argo
  application resources and backend build source into the monorepo-owned path
  after the integration workflow is green and every nested revision is pushed,
  verify backend and console health, and then retire the temporary
  `k8s-cluster` deployment definitions.
- [ ] Move any remaining temporary deployment definitions out of personal
  `k8s-cluster` paths into Sonus-owned GitOps repositories, using deploy keys or
  short-lived GitHub App credentials for private source fetches.
- [ ] Promote the Flutter web console only by updating its exact source pin in
  `~/codes/ores/k8s-cluster/remote/argocd/dd-next-runtime` and allowing Argo to
  reconcile it. Run both Puppeteer and Playwright against the deployed URL.
- [ ] Upgrade or replace Flutter plugins that still depend on legacy Kotlin
  Gradle behavior, lack Apple Swift Package Manager support, or retain StoreKit 1
  APIs before a future Flutter/Xcode release turns warnings into build failures;
  also track the StoreKit 1 deprecation warnings emitted by
  `in_app_purchase_storekit` on macOS 15.

After the accounts are active, create the store records with the existing
identifiers (`com.ores.audioDashcam` for iOS and
`com.ores.sonus_auris` for Android), enroll the signing keys, upload first to
TestFlight and Play internal testing, and complete the store privacy forms. Do
not change either identifier after the first store upload.
