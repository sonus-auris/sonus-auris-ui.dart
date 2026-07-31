# Publishing Sonus Auris — release pathways & compliance checklist

This document is the single entry point for shipping the app to the **Google Play
Store** and the **Apple App Store**, and for installing a controlled Android
acceptance build on physical hardware.

Local scripts build and sign artifacts only; they never upload. Protected GitHub
workflows can publish only after an explicit manual dispatch, approval of the
`mobile-production` environment, and an explicit publication input. Pull requests
and ordinary pushes cannot publish a store build.

- Google Play listing name: **Sonus Auris - Audio Dashcam**
- In-app product name: **Sonus Auris** (Flutter project `audio_dashcam`)
- Android applicationId: `com.ores.sonus_auris`
- iOS bundle id: `com.ores.audioDashcam`
- Version source of truth: `pubspec.yaml` → `version: <name>+<build>` (e.g. `1.0.0+1`)
- Website / marketing URL: `https://sonusauris.app/`
- Support URL: `https://sonusauris.app/support/`
- Privacy policy URL: `https://sonusauris.app/privacy/`
- Account deletion URL: `https://sonusauris.app/account-deletion/`

## Monetization contract

- The initial Google Play release is a one-time paid app.
- Every verified purchaser from the paid-app era receives a permanent
  `lifetime` / Founders entitlement after signing in. That entitlement has no
  period end and must never be downgraded or replaced by a subscription.
- A future subscription may fund recurring-cost services for later customers,
  but Lifetime users are exempt from every Sonus Auris subscription gate. They
  are never required to subscribe to retain or unlock app functionality.
- Before changing the Play download to free or launching subscriptions, deploy
  server-side Play-license verification and the immutable Lifetime grant. Test
  reinstall, account restoration, device replacement, and subscription webhook
  handling against a grandfathered account.

## What's in this repo to support release

| Path | Purpose |
|---|---|
| `scripts/release/bump-version.sh` | Bump marketing version / build number in `pubspec.yaml` |
| `scripts/release/preflight.sh` | Pre-release gate: analyze, test, verify signing + compliance files exist |
| `scripts/release/android-generate-keystore.sh` | Create the **upload keystore** (local, never committed) |
| `scripts/release/android-build-aab.sh` | Build a signed Play **App Bundle** (`.aab`) |
| `scripts/release/android-build-apk.sh` | Build and signature-verify a signed Android **APK** for controlled physical-device acceptance |
| `scripts/release/ios-build-ipa.sh` | Build a signed App Store **IPA** |
| `android/key.properties.example` | Template for Android signing config (copy → `key.properties`) |
| `android/fastlane/` | fastlane `supply` lanes + Play store listing text |
| `ios/ExportOptions.plist` | `xcodebuild -exportArchive` config (app-store) |
| `ios/fastlane/` | fastlane `deliver`/`pilot` lanes for App Store Connect |
| `docs/compliance/` | Privacy policy, data-safety, privacy labels, permissions rationale, export compliance, account deletion |

## One-time account / portal setup (manual — cannot be scripted)

These require a human with the right accounts; do them once.

### Apple
- [ ] Apple Developer Program membership ($99/yr), **Account Holder** access.
- [ ] App Store Connect → create the app record (bundle id `com.ores.audioDashcam`, SKU, name "Sonus Auris").
- [ ] Certificates: an **Apple Distribution** cert + an **App Store** provisioning profile for the bundle id (or let Xcode "Automatically manage signing" with your team).
- [ ] Set `DEVELOPMENT_TEAM` in `ios/Runner.xcodeproj` (or pass it to the build script) — currently unset.
- [ ] (Optional, recommended) An **App Store Connect API key** (.p8) for fastlane uploads without 2FA friction.

### Google
- [x] Google Play Console account active; paid app record created as
  **Sonus Auris - Audio Dashcam** (package `com.ores.sonus_auris`).
- [ ] Generate the **upload keystore** (`scripts/release/android-generate-keystore.sh`) and enrol in **Play App Signing** (Google holds the app-signing key; you hold the upload key).
- [ ] (Optional, recommended) A Play Console **service account** JSON for API/fastlane uploads.

## Compliance gates (required before either store will approve)

- [ ] **Privacy policy hosted and finalized.** The live page is `https://sonusauris.app/privacy/`; replace its legal-entity/contact/address placeholders before submission.
- [ ] **Account deletion pathway.** In-app deletion is wired through `DELETE /api/mobile/v1/account`; deploy the backend with `SOUND_RECORDER_SUPABASE_SERVICE_ROLE_KEY`, then host the public deletion URL from `docs/compliance/ACCOUNT_DELETION.md` before submission.
- [ ] **Google Play Data Safety** form filled from `docs/compliance/DATA_SAFETY_play.md`.
- [ ] **Apple Privacy "Nutrition Labels"** filled from `docs/compliance/PRIVACY_LABELS_appstore.md`.
- [x] **Apple privacy manifest** bundled at `ios/Runner/PrivacyInfo.xcprivacy` and kept aligned with those labels.
- [ ] **Permissions rationale** ready for reviewers (`docs/compliance/PERMISSIONS_RATIONALE.md`) — mic + **background audio** + location + Bluetooth are all high-scrutiny. Record a demo video showing the recording flow for App Review.
- [ ] **iOS export compliance** confirmed (`docs/compliance/EXPORT_COMPLIANCE.md`) — the documented determination self-classifies the app's standard AES-256-GCM protection as exempt and sets `ITSAppUsesNonExemptEncryption = false`; have the publisher or counsel confirm that determination for the intended countries.
- [ ] **Foreground-service / background-audio justification** (Play "Foreground Service" declaration + Apple background `audio` mode review).
- [x] Android targets API 36, omits restricted exact-alarm/full-screen permissions, and requests user-grantable exact-alarm access only when a schedule is armed.

## Store-console-only items

- [ ] **Content / age rating** — Play IARC questionnaire + App Store age rating.
- [ ] **Screenshots & graphics** — iOS (6.7"/6.5"/5.5" + iPad if supported) and Play (≥2 phone shots + 1024×500 feature graphic). The app must be runnable to capture these; see `android/fastlane/metadata/.../images/README.md`.
- [ ] **App category / contact info / support URL.**
- [ ] **Pricing & availability** (paid price, countries).
- [ ] **Sign in / demo** for reviewers if any gated feature needs it (see iOS review notes).

## Local release flow

Set the production account/backend config before building so the app uses the
built-in Supabase project instead of showing developer project fields:

```bash
export SONUS_BACKEND_BASE_URL="https://YOUR-BACKEND.example"
export SONUS_SUPABASE_URL="https://YOUR-PROJECT.supabase.co"
export SONUS_SUPABASE_ANON_KEY="YOUR-PUBLISHABLE-OR-ANON-KEY"
```

```bash
# 0. Pick versions
scripts/release/bump-version.sh 1.0.0 1

# 1. Gate
scripts/release/preflight.sh

# 2. Build signed artifacts (no upload)
scripts/release/android-build-aab.sh
bash scripts/release/android-build-apk.sh
scripts/release/ios-build-ipa.sh

# 3. Upload — explicit and deliberate:
#    Android: Play Console Internal testing, or the protected Android workflow
#             with publish_to_play=true.
#    iOS:     Transporter/Xcode Organizer, or the protected iOS workflow with
#             upload_to_app_store=true for TestFlight processing.
```

Recommendation: ship to **internal testing / TestFlight first**, never straight to production.

## Direct Android installation for physical-device acceptance

The `.aab` is a Google Play publication artifact and cannot be tapped to install.
Use the signed `app-release.apk` produced by `android-build-apk.sh` or by the
protected Android workflow.

1. Download the complete `sonus-auris-android-<build>` artifact.
2. Verify `app-release.apk` against `SHA256SUMS`.
3. On the Android device, temporarily allow the browser or file manager to
   install unknown apps, then open `app-release.apk` and approve installation.
4. Disable the unknown-app installation permission again.

The direct-install APK uses the upload certificate. If Google Play App Signing
serves the production app with a different app-signing certificate, Android will
not update one installation with the other. Uninstall the sideloaded build before
installing from Google Play. Uninstalling removes that installation's app-private
local audio, keys, settings, and account state, so export anything intentionally
kept first.

For an ADB-connected development machine, the equivalent explicit command is:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## GitHub release builds

CI compiles an unsigned iOS release, builds/tests Android, and builds the desktop
entrypoint on native runners. Signed store artifacts are manual-only jobs
protected by the `mobile-production` GitHub environment:

- The Android workflow produces a signed Play `.aab`, a signature-verified
  direct-install `.apk`, checksums, an install notice, and symbols. It publishes
  the `.aab` only when `publish_to_play=true`.
- The iOS workflow produces the signed App Store `.ipa` and symbols when
  requested. It uploads to App Store Connect only when
  `upload_to_app_store=true`.

Download artifacts and verify their checksums before use. Secret names and the
full test matrix are in `docs/mobile-ci.md`.

See `docs/compliance/` for the per-store form content and `scripts/release/` for the scripts.
