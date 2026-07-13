# ios/Runner

The iOS app target. The Swift here is deliberately thin — it registers native
**bridges** (MethodChannels) for capabilities Dart can't reach directly, and
handles app/notification lifecycle. The heavy logic stays in Dart.

- **[AppDelegate.swift](AppDelegate.swift)** — launch, plugin/bridge
  registration, and routing scheduled-recording local notifications through the
  app so a consent-prompt tap foregrounds it.
- **[SceneDelegate.swift](SceneDelegate.swift)** — Flutter scene/window lifecycle
  (default subclass).
- **[IcloudBridge.swift](IcloudBridge.swift)** — `audio_dashcam/icloud`: writes
  segments into the app's iCloud Drive container (device-driven backup).
- **[ShazamBridge.swift](ShazamBridge.swift)** — `audio_dashcam/shazam`: on-device
  ShazamKit song identification (iOS only).
- **[SleepSensorsBridge.swift](SleepSensorsBridge.swift)** —
  `audio_dashcam/sleep_sensors`: CoreMotion / ambient-light sampling for sleep
  sensing.
- **Info.plist / Runner.entitlements** — permissions usage strings, background
  audio mode, and the iCloud/ShazamKit capabilities.
- **GeneratedPluginRegistrant.\* / Runner-Bridging-Header.h** — Flutter-generated
  glue (do not edit by hand).
