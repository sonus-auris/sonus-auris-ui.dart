# Permissions & sensitive-API rationale

Justifications for store reviewers and the Play declaration forms, plus **review
risks to address before submitting**. The app's permission set is sensitive
(microphone + background audio + location + Bluetooth + exact alarms), so expect
scrutiny on both stores.

## Recording consent versus operating-system capability

A user can explicitly start recording, accept a context-trigger prompt, or arm a
recording schedule. Those actions record user intent; they do **not** override
platform restrictions.

- A live recording session that the user started can continue through normal
  backgrounding/lock while the operating system keeps the process and audio
  session alive.
- Force-quitting on iOS or force-stopping on Android prevents future scheduled
  starts until the user launches the app again.
- Android exact alarms persist a desired schedule state; their background
  callback does not open the microphone or start a microphone foreground service.
- iOS local notifications are reminders/relaunch affordances, not permission to
  relaunch a force-quit app and silently open the microphone.
- Active capture must remain visible through the Android persistent notification
  and iOS system microphone indicator.

See `RECORDING_SCHEDULE_LIMITATIONS.md` for the reviewer-facing behavior matrix.

## Local plaintext and encrypted outbound data

The rolling working audio window may remain plaintext inside the app-private
sandbox for the configured local retention period so approved on-device analysis
can run. App backup is disabled for this cache. Every backup or cross-device-sync
object is encrypted on-device before it leaves the device. Do not claim that all
on-device audio is encrypted at rest while the working plaintext window exists.

The intended release default and maximum supported local plaintext window is
**100 hours**, with support for user-selected shorter values. The current
`AppConfig` constructor and deserialization fallback already use 100 hours. The
remaining release blocker is enforcing that ceiling even when uploads fail or
are disabled, including deletion of sidecars and temporary/derived artifacts.

## iOS (Info.plist usage strings — all present)

| Key | Why |
|---|---|
| `NSMicrophoneUsageDescription` | Core feature; microphone use begins only after Start, an accepted prompt, or an explicitly armed schedule. The usage string also discloses force-quit limitations. |
| `NSLocationWhenInUseUsageDescription` | Optional geotagging, OFF by default. When-in-use only; **no** background location. |
| `NSBluetoothAlways/PeripheralUsageDescription` | Optional: notice nearby devices to offer a scheduled-capture prompt. |
| `UIBackgroundModes: audio` | Continue a user-started live capture while locked or normally backgrounded; it is not a future-start entitlement. |
| `ITSAppUsesNonExemptEncryption = false` | See EXPORT_COMPLIANCE.md. |

## Android (AndroidManifest permissions)

| Permission | Why | Notes / risk |
|---|---|---|
| `RECORD_AUDIO` | Core recording. | Prominent disclosure required before the runtime prompt. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE` | Keep user-started capture alive in background under a visible notification. | Android 14+ needs `foregroundServiceType="microphone"` and a Play Console **Foreground service** declaration with a demo video. The schedule-standby use of a microphone-typed service must be validated against current policy and real devices before release. |
| `POST_NOTIFICATIONS` | Show recording state, controls, schedule reminders, and consent prompts. | Runtime prompt; denied notifications must produce a clear degraded-mode warning. |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | Optional geotagging, OFF by default. | Requires the Play **Location permissions** declaration. No background location requested. |
| `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` | Optional nearby-device prompts. | `BLUETOOTH_SCAN` is marked `neverForLocation`; GPS tagging uses its separate permission. |
| `NEARBY_WIFI_DEVICES` | Optional nearby-device context. | Marked `neverForLocation`; used only for an opt-in schedule prompt. |
| `SCHEDULE_EXACT_ALARM` | Wake at declared schedule boundaries to persist/reconcile desired state. | User-grantable only when a schedule is armed. It does not directly start the microphone from a prohibited background state. |
| `RECEIVE_BOOT_COMPLETED` | Re-arm schedule alarms after reboot. | The receiver must not auto-start microphone capture or a microphone foreground service. |
| `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `INTERNET` | Upload gating to user-controlled storage. | Low-risk. |

## Action items before submission

- [x] Removed restricted `USE_EXACT_ALARM` and unused `USE_FULL_SCREEN_INTENT`.
- [x] Added `neverForLocation` to `BLUETOOTH_SCAN` and `NEARBY_WIFI_DEVICES`.
- [x] Confirmed `foregroundServiceType="microphone"` and added the prominent
      disclosure before the OS permission prompt.
- [x] Documented force-quit/force-stop and killed-process schedule limitations.
- [x] Disclosed that the local working window can remain plaintext while every
      outbound backup/sync object is encrypted on-device.
- [x] Confirmed the configured release default is 100 hours in `AppConfig`.
- [ ] Enforce the 100-hour-or-shorter hard plaintext ceiling even when upload is
      disabled, offline, pending, or failing; delete all sensitive companions.
- [ ] Decide whether Android schedule standby can retain a microphone-typed
      foreground service while the mic is closed; redesign if policy/device tests
      do not support it.
- [ ] Complete the Play **Foreground service** declaration and demo video.
- [ ] Complete the Play **Location permissions** declaration, or ship with
      location disabled and remove the permissions.
- [ ] Record an App Review video showing consent → Start → lock/background → Stop
      → playback, plus the force-quit/scheduled-start limitation.
- [ ] Complete 24-hour and 72-hour physical-device endurance tests on supported
      iPhone and Android hardware.
