# Android microphone foreground-service policy

Last reviewed: July 31, 2026

Linear: DEN-293

## Decision

Sonus Auris uses a microphone-typed foreground service **only while microphone
capture is actually active**. An armed recording schedule is notification-only
standby and does not start or retain a microphone foreground service while the
microphone is closed.

A scheduled start follows one of two paths:

1. If Sonus Auris is already visible and resumed, the in-app timer may reconcile
   the declared window and start capture.
2. If Sonus Auris is backgrounded, killed, rebooting, or otherwise not resumed,
   the timer/alarm does not start capture. Android displays a schedule reminder;
   tapping it foregrounds the app, which then reconciles the current wall-clock
   schedule before opening the microphone.

Scheduled stops remain automatic. They may close a schedule-owned recording from
background state because stopping capture is not a new microphone/FGS launch.
Manual recordings are never stopped by a schedule boundary.

## State and service contract

| State | Microphone | Microphone FGS | User-visible behavior |
|---|---:|---:|---|
| Schedule disabled | closed | stopped | no schedule reminders |
| Schedule armed, outside a window | closed | stopped | next start/stop reminders are registered |
| Start boundary, app backgrounded | closed | stopped | notification asks the user to open Sonus Auris |
| Start boundary, app foregrounded | open | running | persistent “Sonus Auris is recording” notification |
| User-started recording moved to background | open | running | persistent recording notification remains visible |
| Schedule-owned stop boundary | closed | stopped | stop reminder and finalized segment |
| Reboot / boot receiver | closed | stopped | alarms/reminders are re-armed; capture never auto-starts |
| Force-stop | closed | stopped | Android blocks work until the user launches the app again |

`BackgroundCaptureMode.scheduleStandby` remains as a compatibility orchestration
value, but its implementation is deliberately a no-op that also stops any stray
foreground service. It cannot create a microphone service.

## Android implementation boundaries

- `BackgroundCaptureService` starts `ForegroundServiceTypes.microphone` only for
  `BackgroundCaptureMode.recording`.
- `RecordingScheduler` suppresses start transitions while Flutter is not resumed,
  but always delivers stop transitions. On resume it reconciles authoritative
  wall-clock schedule state.
- `PluginSchedulePlatform` registers user-visible local notifications on Android
  and iOS. Android uses exact reminders when the user grants “Alarms & reminders”
  access and an inexact fallback otherwise.
- `scheduleAlarmFired` writes only a pending Boolean state journal. It never calls
  recorder code, starts a service, or changes a manual recording.
- `RebootBroadcastReceiver` exists only to let `android_alarm_manager_plus`
  restore registered alarm state. Foreground-task auto-restart remains disabled.
- The manifest declares only the truthful `microphone` FGS type; it does not
  relabel recording as data sync, media playback, location, or another type.

## Play Console foreground-service declaration draft

**Foreground service type:** Microphone

**Core functionality:** Sonus Auris provides a user-controlled rolling audio
recorder. After the user accepts the recording disclosure and explicitly starts
capture while the app is visible, the microphone foreground service keeps that
same recording session alive when the screen locks or the user switches apps.

**Why interruption breaks the experience:** Stopping the active service when the
app leaves the foreground would create gaps in the rolling evidence/audio window
and break one-minute segment continuity. The service ends immediately when the
user stops recording or a schedule-owned recording reaches its stop boundary.

**User initiation and awareness:** Capture begins only from a visible/resumed app
or after the user taps a schedule/consent notification. While capture is active,
Android shows a persistent notification titled “Sonus Auris is recording.” An
armed schedule by itself does not run a foreground service or access the mic.

**User control:** The user can stop capture in Sonus Auris. Android’s persistent
notification and system foreground-service controls remain visible while the mic
is active. Force-stop terminates the service and capture.

## Reviewer demonstration video script

Record one continuous video on a production-signed internal-track build:

1. Open Android Settings and show Sonus Auris microphone and notification
   permissions.
2. Open Sonus Auris and show the accepted microphone disclosure.
3. Arm a schedule outside its recording window.
4. Show that no recording foreground-service notification is present while the
   schedule is merely armed.
5. Trigger or wait for a start-boundary notification; show its tap-to-open text.
6. Tap the notification and start/reconcile recording while the app is visible.
7. Show the persistent “Sonus Auris is recording” notification.
8. Press Home, lock the screen, wait through at least two segment rotations, and
   show that recording continues.
9. Return to Sonus Auris, stop recording, and show that the foreground service
   and notification disappear.
10. Reboot the device with a schedule armed and show that only reminders are
    restored; microphone capture and the microphone FGS remain stopped.

Do not submit an emulator-only video. Store evidence must use the same signed
candidate and device class used for physical acceptance.

## Automated evidence

The Android CI suite must retain these gates:

- API 34 and API 36 clean install, permission, force-stop/cold-start, and in-place
  update smoke tests;
- integration assertion that schedule standby leaves
  `FlutterForegroundTask.isRunningService == false`;
- real microphone-to-WAV capture and overlapping segment rotation;
- host-driven Home transition proving a user-started recording process, service,
  notification, and PCM stream remain alive;
- unit tests proving background start transitions are deferred until resume,
  stop transitions still fire, exact permission denial falls back to an inexact
  reminder, and alarm callbacks remain state-only.

## Physical evidence still required

Before DEN-293 can be considered fully closed for store submission, run the
production-signed candidate on the current Samsung handset and at least one
reference Android device through:

- notifications allowed and denied;
- screen lock and unlock;
- swipe-away from Recents;
- Doze and battery saver;
- reboot with an armed schedule;
- force-stop and explicit relaunch;
- microphone permission revocation during recording;
- Samsung battery optimization / sleeping-app controls;
- incoming call, Bluetooth route change, and audio-focus interruption.

Record timestamps, Android version, OEM build, permission state, notification
screenshots/video, segment counts, gaps, crashes, and battery/storage deltas.

## Primary policy references

- Android Developers — Restrictions on starting a foreground service from the background: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- Android Developers — Foreground service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- Android Developers — Android 15 foreground-service changes: https://developer.android.com/about/versions/15/changes/foreground-service-types
- Android Developers — Schedule alarms: https://developer.android.com/develop/background-work/services/alarms/schedule
- Google Play Help — Understanding foreground service and full-screen intent requirements: https://support.google.com/googleplay/android-developer/answer/13392821
- Google Play Help — Permissions for foreground services: https://support.google.com/googleplay/android-developer/answer/13392821#fgs
