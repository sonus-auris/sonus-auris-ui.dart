# ios

The iOS host project for the Flutter app. Most app behaviour lives in Dart under
`lib/`; this folder is the native shell, entitlements/Info.plist, native bridges,
and store metadata.

- **[Runner/](Runner/)** — the app target: `AppDelegate`, `Info.plist`,
  `Runner.entitlements`, and the Swift MethodChannel bridges (iCloud, ShazamKit,
  sleep sensors). See [Runner/README.md](Runner/README.md).
- **[RunnerTests/](RunnerTests/)** — the XCTest target (placeholder; app logic is
  tested in Dart under `test/`).
- **[fastlane/](fastlane/)** — App Store deploy lanes and `metadata/`.
- **ICLOUD_SETUP.md** — how to enable the iCloud Documents container the iCloud
  bridge writes into (Apple has no server-side iCloud write API, so backup is
  device-driven).
- **ExportOptions.plist** — Xcode export options used by `ios-build-ipa.sh`.
