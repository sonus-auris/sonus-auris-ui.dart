# Continuous and scheduled recording behavior

Last reviewed: July 27, 2026.

This document is the canonical behavior contract for the mobile app, reviewer
notes, support responses, automated tests, and marketing copy. It separates a
user's consent/intent from the execution capabilities iOS and Android provide.

## Consent contract

Recording may begin only after the user:

1. taps **Start**;
2. accepts a specific in-app or notification prompt; or
3. explicitly enables and saves a recording schedule after reviewing the
   recording disclosure.

A schedule is durable user intent for its declared device, timezone, days, and
windows. It is not a way to bypass permissions, force-quit/force-stop, or
background-execution restrictions.

## Platform behavior matrix

| State | Android | iOS |
|---|---|---|
| User starts recording while app is foregrounded | Start microphone capture and the visible microphone foreground service | Start the audio session; the system microphone indicator appears |
| User locks screen or switches apps during a live session | Continue while the foreground service/process remains permitted | Continue while the live background-audio session remains active |
| A schedule boundary occurs while the app/process is alive | In-app timer reconciles capture against the saved schedule | In-app timer reconciles capture against the saved schedule |
| Exact alarm/local notification fires while capture is not active | Alarm callback records desired state only; it must not directly open the microphone from a prohibited background receiver | Notification reminds/relaunches; it does not silently start microphone capture |
| App is swiped away / process reclaimed | Behavior varies by OS/device; never promise guaranteed future start | Future start is not guaranteed; live session may end if the process is terminated |
| User force-stops or force-quits | No future scheduled start until the user launches the app again | No future scheduled start until the user launches the app again |
| Device reboots | Re-arm schedule metadata/alarms; do not auto-start microphone capture from the boot receiver | User must relaunch; do not promise automatic capture after reboot |
| Permission is revoked | Stop/fail closed and show remediation | Stop/fail closed and show remediation |

## Visible state requirements

- The Home screen must clearly distinguish **Off**, **Schedule armed**,
  **Starting**, **Recording**, **Paused**, **Interrupted**, and **Permission
  required**.
- Android must use a truthful persistent notification with immediate Stop/Pause
  controls whenever capture is active. Schedule standby must not imply that the
  microphone is recording.
- iOS relies on its system microphone indicator during active capture; the app
  must also show its own obvious state and controls.
- Never use covert, hidden, misleading, or dismissible-only recording state.

## Android foreground-service review question

The current implementation uses the same microphone-typed foreground service for
recording and schedule standby. Before release, confirm through current policy,
API behavior, and physical-device tests whether a microphone-typed service may
remain active while the microphone is closed merely to keep a schedule timer
alive.

If that design is not accepted or reliable, replace it with one of these truthful
models:

1. a user-started continuous recording session that remains active through the
   declared period;
2. a schedule notification that requires a user action to start capture; or
3. another reviewed platform-supported mechanism that does not claim prohibited
   background microphone access.

Do not relabel a microphone function as another foreground-service type merely to
avoid policy review.

## Test matrix

Run production-signed builds on physical devices across:

- 24-hour and 72-hour live sessions;
- screen lock/unlock and app switching;
- phone calls, Siri/Assistant, alarms, media playback, Bluetooth route changes,
  headset disconnect, and audio focus loss;
- network loss/recovery, offline upload backlog, low battery, battery saver,
  Doze, thermal pressure, and low storage;
- process reclaim, swipe-away, force-stop/force-quit, reboot, OS update, and app
  upgrade;
- daylight-saving/timezone change, overlapping windows, edited schedules, and
  stale alarm callbacks;
- permission denial/revocation and notification denial;
- segment continuity, overlap, retention deletion, encryption, and recovery.

Preserve evidence: device/OS/build, exact steps, timestamps, screenshots/video,
system logs, app diagnostics, battery/thermal/storage metrics, segment hashes,
and pass/fail conclusions.

## Reviewer wording

Use language equivalent to:

> Sonus Auris records only after the user starts recording, accepts a prompt, or
> explicitly arms a schedule. A live recording can continue while the device is
> locked or the app is normally backgrounded. The app does not bypass force-quit,
> force-stop, permission, or operating-system restrictions, and it always shows
> the platform recording indicator or persistent notification while recording.

Marketing, support, onboarding, privacy, and store metadata must not promise
"guaranteed 24/7 recording" or "automatic recording even when the app is killed."
