# android

The Android host project for the Flutter app (Gradle Kotlin DSL). Most app
behaviour lives in Dart under `lib/`; this folder is the native shell,
permissions/manifest, signing config, and store metadata.

- **[app/](app/)** — the application module: `build.gradle.kts`, the manifest and
  resources under `app/src/main/`, and the Kotlin host activity under
  `app/src/main/kotlin/com/ores/audio_dashcam/` (which also hosts the sleep-sensor
  method channel — see its README).
- **[fastlane/](fastlane/)** — Play Store deploy lanes and `metadata/` (listing
  text, changelogs, images).
- **build.gradle.kts / settings.gradle.kts / gradle.properties** — top-level
  Gradle build config.
- **key.properties.example** — template for the signing config consumed by the
  release build (the real `key.properties` is never committed; see
  `scripts/release/android-generate-keystore.sh`).
