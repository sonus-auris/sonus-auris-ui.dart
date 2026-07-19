# Publishing Sonus Auris — release pathways & compliance checklist

This document is the single entry point for shipping the app to the **Google Play
Store** and the **Apple App Store**. Everything here is set up so the app is
*ready and compliant* — **nothing here publishes the app**. The build scripts
produce signed artifacts locally; uploading is an explicit, separate, manual
(or fastlane) step you trigger deliberately.

- App name: **Sonus Auris** (Flutter project `audio_dashcam`)
- Android applicationId: `com.ores.audio_dashcam`
- iOS bundle id: `com.ores.audioDashcam`
- Version source of truth: `pubspec.yaml` → `version: <name>+<build>` (e.g. `1.0.0+1`)
- Website / marketing URL: `https://sonusauris.app/`
- Support URL: `https://sonusauris.app/support/`
- Privacy policy URL: `https://sonusauris.app/privacy/`
- Account deletion URL: `https://sonusauris.app/account-deletion/`

## What's in this repo to support release

| Path | Purpose |
|---|---|
| `scripts/release/bump-version.sh` | Bump marketing version / build number in `pubspec.yaml` |
| `scripts/release/preflight.sh` | Pre-release gate: analyze, test, verify signing + compliance files exist |
| `scripts/release/android-generate-keystore.sh` | Create the **upload keystore** (local, never committed) |
| `scripts/release/android-build-aab.sh` | Build a signed Play **App Bundle** (`.aab`) |
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
- [ ] Google Play Console account ($25 one-time), app created (package `com.ores.audio_dashcam`).
- [ ] Generate the **upload keystore** (`scripts/release/android-generate-keystore.sh`) and enrol in **Play App Signing** (Google holds the app-signing key; you hold the upload key).
- [ ] (Optional, recommended) A Play Console **service account** JSON for fastlane `supply` uploads.

## Compliance gates ("the wing dings") — required before either store will approve

- [ ] **Privacy policy hosted and finalized.** The live page is `https://sonusauris.app/privacy/`; replace its legal-entity/contact/address placeholders before submission.
- [ ] **Account deletion pathway.** In-app deletion is wired through `DELETE /api/mobile/v1/account`; deploy the backend with `SOUND_RECORDER_SUPABASE_SERVICE_ROLE_KEY`, then host the public deletion URL from `docs/compliance/ACCOUNT_DELETION.md` before submission.
- [ ] **Google Play Data Safety** form filled from `docs/compliance/DATA_SAFETY_play.md`.
- [ ] **Apple Privacy "Nutrition Labels"** filled from `docs/compliance/PRIVACY_LABELS_appstore.md`.
- [x] **Apple privacy manifest** bundled at `ios/Runner/PrivacyInfo.xcprivacy` and kept aligned with those labels.
- [ ] **Permissions rationale** ready for reviewers (`docs/compliance/PERMISSIONS_RATIONALE.md`) — mic + **background audio** + location + Bluetooth are all high-scrutiny. Record a demo video showing the recording flow for App Review.
- [ ] **iOS export compliance** confirmed (`docs/compliance/EXPORT_COMPLIANCE.md`) — the documented determination self-classifies the app's standard AES-256-GCM protection as exempt and sets `ITSAppUsesNonExemptEncryption = false`; have the publisher or counsel confirm that determination for the intended countries.
- [ ] **Foreground-service / background-audio justification** (Play "Foreground Service" declaration + Apple background `audio` mode review).
- [x] Android targets API 36, omits restricted exact-alarm/full-screen permissions, and requests user-grantable exact-alarm access only when a schedule is armed.

## Store-console-only items (no file in repo — done in the dashboards)

- [ ] **Content / age rating** — Play IARC questionnaire + App Store age rating.
- [ ] **Screenshots & graphics** — iOS (6.7"/6.5"/5.5" + iPad if supported) and Play (≥2 phone shots + 1024×500 feature graphic). The app must be runnable to capture these; see `android/fastlane/metadata/.../images/README.md`.
- [ ] **App category / contact info / support URL.**
- [ ] **Pricing & availability** (free, countries).
- [ ] **Sign in / demo** for reviewers if any gated feature needs it (see iOS review notes).

## Release flow (once the above is done)

Set the production account/backend config before building so the app uses the
built-in Supabase project instead of showing developer project fields:

```bash
export SONUS_BACKEND_BASE_URL="https://YOUR-BACKEND.example"
export SONUS_SUPABASE_URL="https://YOUR-PROJECT.supabase.co"
export SONUS_SUPABASE_ANON_KEY="YOUR-PUBLISHABLE-OR-ANON-KEY"
```

```bash
# 0. Pick versions
scripts/release/bump-version.sh 1.0.0 1        # marketing 1.0.0, build 1

# 1. Gate
scripts/release/preflight.sh                   # analyze + test + checks

# 2. Build signed artifacts (no upload)
scripts/release/android-build-aab.sh           # -> build/app/outputs/bundle/release/app-release.aab
scripts/release/ios-build-ipa.sh               # -> build/ios/ipa/*.ipa   (macOS + Xcode only)

# 3. Upload — EXPLICIT, manual:
#    Android: Play Console "Internal testing" track, or `cd android && fastlane internal`
#    iOS:     Transporter / Xcode Organizer, or `cd ios && fastlane beta`  (TestFlight)
```

Recommendation: ship to **internal testing / TestFlight first**, never straight to production.

## GitHub release builds

CI always compiles an unsigned iOS release on `macos-15`, builds Android and
tests on Linux, and builds the desktop entrypoint on native Linux, macOS, and
Windows runners. Signed store artifacts are manual-only jobs protected by the
`mobile-production` GitHub environment:

- `android release` produces the Play `.aab` from an ephemeral upload keystore.
- `iOS build` produces the App Store `.ipa` from an ephemeral distribution
  certificate and provisioning profile.

Neither job uploads or publishes. Download the artifact, verify its checksum,
then explicitly upload it to the internal-testing track or TestFlight. Secret
names and the full test matrix are in `docs/mobile-ci.md`.

See `docs/compliance/` for the per-store form content and `scripts/release/` for the scripts.
