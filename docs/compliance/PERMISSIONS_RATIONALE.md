# Permissions & sensitive-API rationale

Justifications for store reviewers and the Play declaration forms, plus **review
risks to address before submitting**. The app's permission set is sensitive
(microphone + background audio + location + Bluetooth + exact alarms), so expect
scrutiny on both stores.

## iOS (Info.plist usage strings — all present)
| Key | Why |
|---|---|
| `NSMicrophoneUsageDescription` | Core feature; mic used **only after** the user taps Start. |
| `NSLocationWhenInUseUsageDescription` | Optional geotagging, OFF by default. When-in-use only; **no** background location. |
| `NSBluetoothAlways/PeripheralUsageDescription` | Optional: notice nearby devices to offer a scheduled-capture prompt. |
| `UIBackgroundModes: audio` | Continuous capture while locked (e.g. overnight). Session starts only after Start. |
| `ITSAppUsesNonExemptEncryption = false` | See EXPORT_COMPLIANCE.md. |

## Android (AndroidManifest permissions)
| Permission | Why | Notes / risk |
|---|---|---|
| `RECORD_AUDIO` | Core recording. | Prominent disclosure required. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE` | Keep capturing in background under a visible notification. | Android 14+ needs the service declared `foregroundServiceType="microphone"` **and** a Play Console **Foreground service** declaration with a short video. |
| `POST_NOTIFICATIONS` | Show the capture/notification UI. | Runtime prompt; fine. |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | Optional geotagging, OFF by default. | Requires the Play **Location permissions** declaration. No background location requested (good). |
| `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` | Optional nearby-device prompts. | Add `android:usesPermissionFlags="neverForLocation"` to `BLUETOOTH_SCAN` if you don't derive location from it (reduces scrutiny). |
| `NEARBY_WIFI_DEVICES` | Optional nearby-device context. | Add `neverForLocation` flag; justify or drop if unused in the shipped build. |
| `SCHEDULE_EXACT_ALARM` | Fire scheduled-recording windows precisely. | Play **exact-alarm policy**: allowed only if exact timing is core. Be ready to justify. |
| `USE_EXACT_ALARM` | (same) | ⚠️ **Highest rejection risk.** `USE_EXACT_ALARM` is restricted to **alarm clock / calendar / timer** apps. A recorder likely does **not** qualify — recommend **removing it** and relying on `SCHEDULE_EXACT_ALARM` (user-grantable) or `setInexactRepeating`/WorkManager. |
| `RECEIVE_BOOT_COMPLETED` | Re-arm scheduled windows after reboot. | Justify; common and low-risk. |
| `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `INTERNET` | Upload gating to user-controlled storage. | Low-risk. |

## Action items before submission
- [ ] Remove `USE_EXACT_ALARM` unless the app is genuinely an alarm-clock app.
- [ ] Add `android:usesPermissionFlags="neverForLocation"` to `BLUETOOTH_SCAN`
      (and `NEARBY_WIFI_DEVICES`) if not used to derive location; drop any you
      don't actually use in the shipped build.
- [ ] Confirm the foreground service is declared `foregroundServiceType="microphone"`
      and complete the Play **Foreground service** declaration (+ demo video).
- [ ] Complete the Play **Location permissions** declaration (or ship with location
      disabled and drop the permissions).
- [ ] Add a **prominent in-app disclosure** before first recording explaining
      that audio is captured (and may run in the background).
- [ ] Record a short demo video for App Review showing Start → background capture
      → Stop → playback (covers mic + background `audio` justification).
