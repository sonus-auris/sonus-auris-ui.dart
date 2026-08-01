# scripts/release

Scripts for signed release artifacts. The local scripts **build and sign only**;
they never upload. Protected GitHub workflows can upload only after an explicit
manual dispatch and the corresponding publication input is enabled. Run
`preflight.sh` first; see the repo-root `PUBLISHING.md` for the full release flow.

- **[preflight.sh](preflight.sh)** — read-only pre-release gate; non-zero exit if
  a hard gate fails, warnings for soft gates (compliance docs, signing).
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
