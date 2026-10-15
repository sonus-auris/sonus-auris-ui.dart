# Mobile legal review bundle

Status: review implementation; production legal use blocked. Owner: mobile release and legal owners (assignment pending). Editorial review: 2026-09-06. No qualified legal approval or store submission is implied.

The canonical text is in sonus-auris/sonus-auris-docs at commit `8e21168887f32b627328adcbb7f9978d178011e5`. Its `contracts/mobile-legal.json` allowlists exactly three external drafts. `assets/legal/manifest.json` records that immutable source and Git blob hashes/byte lengths. The Markdown snapshots are generated derivatives: **do not edit them here**. No internal legal, signed, equity, personnel, incident or privileged documents are packaged.

## Packaging and update

pubspec.yaml declares each file explicitly, so ordinary Flutter Android/iOS builds include them as offline assets. Committed byte-for-byte snapshots avoid fragile external symlinks, runtime GitHub credentials or a cross-repository network dependency during builds. This is not a claim that a Zed package has been published. A future Zed package adapter must preserve this exact external allowlist and source/approval verification; it cannot infer licensing or approval from package presence.

To recreate the pinned snapshots from an already authorized docs checkout, set `SONUS_LEGAL_SOURCE_DIR` to that checkout and run `node scripts/legal/sync-from-docs.mjs`. It requires the exact pinned commit, reads committed bytes rather than dirty working files, verifies the canonical allowlist and hashes, and writes only the three asset files. To upgrade, first review and merge the owning docs changes, update the consumer manifest in a PR, regenerate explicit files and rerun source/widget/artifact checks. Do not put access tokens in commands or remotes.

## Checks and review UI

Run `node --test scripts/legal/bundle.test.mjs`, `node scripts/legal/verify-source.mjs` and `flutter test test/legal_review_bundle_test.dart`. The mobile canary builds the ordinary app as an Android debug APK and iOS simulator app and inspects actual bundle bytes with `SONUS_LEGAL_ARTIFACT` plus `node scripts/legal/verify-artifact.mjs`. Source checks alone are not proof of successful platform compilation. CI records actual results; no local Flutter or physical-device build is claimed here.

For an explicit offline reader, run `flutter run -t lib/main_legal_review.dart`. The modular page verifies hashes, labels everything as a draft and provides no acceptance button or consent/telemetry write. It is a review entrypoint, not a new link in the production settings screen. Existing public privacy/account-deletion/support links and permission/recording flows remain untouched. Product-navigation integration, accessibility/localization and actual device review remain release tasks. Rust desktop packaging parity is not delivered by this mobile PR.

## Production boundary

The existing Android AAB/APK and iOS IPA signing helpers invoke `scripts/legal/require-production.mjs` before Flutter builds. Version 1 is intentionally review-only and refuses production use; neither an environment flag nor flipping `approvedForRelease` can approve these drafts. A future approved release needs completed legal text, actual business/counsel evidence, an independently reviewed release-contract change and corresponding tests. Unsigned compile/debug checks may inspect drafts; they do not authorize Play/TestFlight upload.

The helper gate does not claim to intercept arbitrary direct `flutter build` commands or every external CI system. Release operators must use the reviewed helpers and protected workflows; do not publish manually compiled drafts. Existing signed workflow/environment protections are not weakened. No signing credentials or store actions were used by this task.

Bundled drafts are not a substitute for an accurate live privacy policy, normal-flow prominent disclosures, account deletion, app-store metadata, applicable Apple EULA terms or independent recording/backup/analysis/research/sharing consent. Qualified legal approval must match the exact app/text versions and actual shipped behavior. No retention ceiling, hold, consent flag, capture, encryption or upload behavior is changed.
