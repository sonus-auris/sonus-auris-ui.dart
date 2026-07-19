# Publishing follow-ups

Last reviewed: July 18, 2026.

Resume these account and console steps at a later date. The pages may ask you
to sign in again before continuing.

- [ ] Finish Apple Developer Program enrollment and billing:
  [Apple checkout](https://secure7.store.apple.com/shop/checkout?_s=Billing)
- [ ] Create or finish the Sonus Auris App Store Connect app record:
  [App Store Connect apps](https://appstoreconnect.apple.com/apps)
- [ ] Finish Google Play developer-account registration, then create the app:
  [Google Play Console signup](https://play.google.com/console/signup)
- [ ] Review and retain access to the Supabase server-side API credentials:
  [Supabase legacy API keys](https://supabase.com/dashboard/project/mckxblyvfzyoxpwvrnjm/settings/api-keys/legacy)
- [ ] Set up a Cloudflare R2 bucket for Sonus Auris, configure its S3-compatible
  endpoint and scoped credentials in the backend secret store, and define the
  production retention/lifecycle policy.

## Build and deployment readiness

- [ ] Create the protected GitHub `mobile-production` environment and add the
  production backend/Supabase values plus Android and Apple signing secrets
  documented in `docs/mobile-ci.md`.
- [ ] Point `SONUS_BACKEND_BASE_URL` at the Sonus-owned cluster hostname after
  `api.sonusauris.app` DNS, TLS, and gateway routing are declared through Argo.
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
`com.ores.audio_dashcam` for Android), enroll the signing keys, upload first to
TestFlight and Play internal testing, and complete the store privacy forms.
