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
| `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` | Optional nearby-device prompts. | `BLUETOOTH_SCAN` is marked `neverForLocation`; GPS tagging uses its separate permission. |
| `NEARBY_WIFI_DEVICES` | Optional nearby-device context. | Marked `neverForLocation`; used only for an opt-in schedule prompt. |
| `SCHEDULE_EXACT_ALARM` | Fire scheduled-recording windows precisely. | User-grantable only when a schedule is armed; denied access degrades to the live in-app timer. |
| `RECEIVE_BOOT_COMPLETED` | Re-arm scheduled windows after reboot. | Justify; common and low-risk. |
| `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `INTERNET` | Upload gating to user-controlled storage. | Low-risk. |

## Action items before submission
- [x] Removed restricted `USE_EXACT_ALARM` and unused `USE_FULL_SCREEN_INTENT`.
- [x] Added `neverForLocation` to `BLUETOOTH_SCAN` and `NEARBY_WIFI_DEVICES`.
- [x] Confirmed `foregroundServiceType="microphone"` and added the prominent
      disclosure before the OS permission prompt.
- [ ] Complete the Play **Foreground service** declaration (+ demo video).
- [ ] Complete the Play **Location permissions** declaration (or ship with location
      disabled and drop the permissions).
- [ ] Record a short demo video for App Review showing Start → background capture
      → Stop → playback (covers mic + background `audio` justification).
