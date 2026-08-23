# Isolated Android microphone-permission denial lab

This runbook exercises the failure path where microphone access is already in a
user-fixed denied state. It complements the real-recording probe without opening
a microphone or changing permission state for either production Sonus Auris or
the recording device lab.

## Three separate Android identities

The Gradle build selects exactly one identity:

| Purpose | Application ID | Visible label | Callback scheme |
| --- | --- | --- | --- |
| Production | `com.ores.sonus_auris` | Sonus Auris | `sonusauris://` |
| Real recording | `com.ores.sonus_auris.device_lab` | Sonus Auris Device Lab | `sonusauris-device-lab://` |
| Permission denial | `com.ores.sonus_auris.permission_lab` | Sonus Auris Permission Lab | `sonusauris-permission-lab://` |

`SONUS_DEVICE_LAB_ANDROID=1` and `SONUS_PERMISSION_LAB_ANDROID=1` are mutually
exclusive. Both lab identities are debug-only; Gradle refuses every release task
graph while either is selected.

The host verifies the APK application ID before changing a permission. It
explicitly refuses production and the recording-lab package.

## What the probe proves

For the permission-lab package only, the host:

1. installs the isolated debug APK in place;
2. revokes `android.permission.RECORD_AUDIO`;
3. clears stale permission-decision flags, then sets `user-set` and `user-fixed`;
4. verifies `granted=false` before starting Flutter;
5. runs a compile-time-gated integration target;
6. requires an actionable permission error from `SegmentRecorder.start`;
7. requires recorder state to return to idle;
8. requires the microphone foreground service to remain absent;
9. requires the RECORD_AUDIO app-op not to become allowed/foreground; and
10. requires zero `.wav` or `.part` artifacts before and after cleanup.

The package is force-stopped but not uninstalled. Production and the recording
lab are never addressed by ADB. Shared logcat is never cleared.

This test needs no recording-consent phrase because it is constructed to deny
microphone access before the app requests it. Any unexpected capture or service
startup fails the run.

## Run on the USB-attached Android handset

From the Flutter repository on the MacBook:

```bash
ANDROID_SERIAL=<authorized-adb-serial> \
  bash scripts/device-lab/android-permission-denial-probe.sh
```

The intended handset must be unlocked and visible as `device` in:

```bash
adb devices -l
```

When more than one Android target is visible, `ANDROID_SERIAL` is required.
Emulators are refused by default; hosted CI opts in explicitly.

## Run from the complete Mac device lab

The denial probe is a separate opt-in target:

```bash
ANDROID_SERIAL=<authorized-adb-serial> \
SONUS_RUN_IOS_DEVICE=1 \
SONUS_RUN_ANDROID_DEVICE=1 \
SONUS_RUN_ANDROID_PERMISSION_DENIAL_PROBE=1 \
SONUS_RUN_ANDROID_RECORDING_PROBE=1 \
SONUS_ANDROID_RECORDING_PROBE_CONSENT=I_CONSENT_TO_A_15_SECOND_SONUS_DEVICE_LAB_RECORDING \
  bash scripts/device-lab/macos-end-device-smoke.sh
```

The permission-denial target uses `com.ores.sonus_auris.permission_lab`; the
real-recording target uses `com.ores.sonus_auris.device_lab`. Their permission
flags, app sandboxes, deep links, services, and app-op evidence are independent.

## Evidence

Standalone evidence is written under:

```text
build/device-lab/android-permission-<UTC timestamp>/
```

The shareable directory contains only bounded metadata and diagnostics:

- a short hash of the ADB serial;
- Android SDK/security-patch metadata;
- the isolated APK digest and verified application ID;
- the permission-lab `dumpsys package` permission line and flags;
- content-free Flutter result/cleanup markers;
- service and RECORD_AUDIO app-op evidence; and
- explicit statements that production and recording lab were not addressed,
  no foreground service started, no raw audio was exported, and no test audio
  artifact existed.

`scripts/device-lab/evidence-policy.py` sanitizes live output and stored text,
waits for writers to close, rejects raw audio/key/provisioning artifacts and
symlinks, and fails if recognized secrets or local identifiers remain.

## Hosted gate

The API 34 workflow runs the permission-denial probe and the real-recording probe
sequentially on one KVM emulator. The separate application IDs are intentional:
the user-fixed denial remains scoped to the permission lab while the recording
lab receives its own explicit microphone grant and virtual input.

A hosted pass does not establish behavior on the operator-owned Samsung device.
OEM permission UI, process-kill behavior, power management, USB transport, and
installed Android version still require the command above.
