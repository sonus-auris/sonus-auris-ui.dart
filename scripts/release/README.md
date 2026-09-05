# scripts/release

Scripts for signed release artifacts. The local scripts **build and sign only**;
they never upload. Protected GitHub workflows can upload only after an explicit
manual dispatch and the corresponding publication input is enabled. Run
`preflight.sh` first; see the repo-root `PUBLISHING.md` for the full release flow.

The durable Android/Google Play identity is `com.ores.sonus_auris`. The earlier
`com.ores.audio_dashcam` identifier is not a supported publication target and has
no store migration role. The release workflow fails before compilation when its
package target diverges from Gradle, then inspects the built AAB with a pinned,
checksum-verified bundletool and confirms its signer matches the configured upload
keystore before any Google Play edit can be created.

- **[preflight.sh](preflight.sh)** — read-only pre-release gate; non-zero exit if
  a hard gate fails, warnings for soft gates (compliance docs, signing).
- **[check_android_package_contract.py](check_android_package_contract.py)** —
  fail-closed static comparison of Gradle and both Play publication calls.
- **[verify-android-publication.sh](verify-android-publication.sh)** — inspect the
  exact AAB package and compare its SHA-256 signing-certificate fingerprint with
  the protected upload keystore.
- **[bump-version.sh](bump-version.sh)** — bump `version:` in `pubspec.yaml` (the
  single source of truth for both stores' version/build numbers).
- **[android-generate-keystore.sh](android-generate-keystore.sh)** — create the
  Android upload keystore + `android/key.properties` (never committed).
- **[android-build-aab.sh](android-build-aab.sh)** — build a signed Play App
  Bundle (`.aab`) plus symbols.
- **[android-build-apk.sh](android-build-apk.sh)** — build and signature-verify a
  signed `.apk` for controlled physical-device acceptance. This is not a Play
  artifact; use the `.aab` for Play publication.
- **[ios-build-ipa.sh](ios-build-ipa.sh)** — build a signed App Store `.ipa`
  (macOS + Xcode only).
- **[generate-store-assets.sh](generate-store-assets.sh)** — regenerate branded
  iOS/Android launcher icons plus Play icon/feature graphic (ImageMagick 7).
- **[verify-store-assets.sh](verify-store-assets.sh)** — verify required
  dimensions and OCR-check both account screenshots for current passwordless
  six-digit email-code copy (`tesseract` required).
