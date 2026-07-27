# Publishing follow-ups

Last reviewed: July 27, 2026.

The repository now contains the build, upload, installer-signing, notarization,
and R2 publication paths. The remaining blockers are account enrollment,
production credentials, store records/metadata, and physical-device acceptance.
These pages may ask an account owner to sign in again.

- [ ] Finish Apple Developer Program enrollment and billing:
  [Apple checkout](https://secure7.store.apple.com/shop/checkout?_s=Billing)
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

## Protected GitHub environments

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
