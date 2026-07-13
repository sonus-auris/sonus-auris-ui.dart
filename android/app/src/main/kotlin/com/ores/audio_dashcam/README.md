# android/app/src/main/kotlin/com/ores/audio_dashcam

The Android native (Kotlin) host code. Almost all logic is in Dart; the native
side is kept minimal and exists mainly to host platform method channels the Dart
services call.

- **[MainActivity.kt](MainActivity.kt)** — the `FlutterActivity` host. Beyond
  standard engine setup it serves the `audio_dashcam/sleep_sensors` method
  channel, sampling the accelerometer (motion stillness) and the light sensor
  (ambient lux) as extra sleep-sensing signals for `SleepSensorService`.
