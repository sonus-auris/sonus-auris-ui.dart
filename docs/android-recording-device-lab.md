# Isolated Android real-microphone device lab

This runbook adds an **opt-in** recording/background probe for an authorized
Android handset attached to the MacBook. It complements the default
non-destructive launch/relaunch smoke in `scripts/device-lab/` and the existing
KVM emulator recording matrix.

The probe is deliberately not part of the default device-lab run because it
opens a real microphone. It requires an exact consent phrase on every run.

## Safety boundary

The probe never runs under the Play Store identity
`com.ores.sonus_auris`. While `SONUS_DEVICE_LAB_ANDROID=1` is present, Gradle
builds the debug-only package:

```text
com.ores.sonus_auris.device_lab
```

That package has:

- a separate Android app sandbox and preferences domain;
- the visible label **Sonus Auris Device Lab**;
- the separate callback scheme `sonusauris-device-lab://` so it cannot claim
  production auth, invite, or OAuth callbacks; and
- a release-task guard, so the device-lab application ID cannot be packaged as a
  release artifact.

The host harness verifies the APK application ID before installation or any
permission grant. It refuses the production application ID. It never sends an
ADB command to the production package, never uninstalls either package, never
clears either app's data, and never clears the shared device logcat buffer.

The isolated test records for about 15 seconds, rotates one-second WAV segments,
presses Home while the microphone foreground service is active, verifies the
process/service/notification, returns the activity to the foreground, validates
WAV headers and sample continuity inside the test sandbox, then deletes its own
WAV and partial files. Raw audio is never copied into evidence.

## Prerequisites

On the MacBook:

```bash
flutter doctor -v
adb devices -l
```

The intended handset must be unlocked and listed as `device`, not
`unauthorized` or `offline`. With multiple Android targets attached, set
`ANDROID_SERIAL` explicitly.

The script requires `flutter`, `adb`, Python 3, and either `apkanalyzer` or
`aapt` from the Android SDK. It also requires `shasum` or `sha256sum`.

## Run only the isolated recording probe

From the repository root:

```bash
ANDROID_SERIAL=<authorized-adb-serial> \
SONUS_ANDROID_RECORDING_PROBE_CONSENT=I_CONSENT_TO_A_15_SECOND_SONUS_DEVICE_LAB_RECORDING \
  bash scripts/device-lab/android-recording-probe.sh
```

The exact phrase is intentional. A missing, abbreviated, or modified value exits
before build, install, permission mutation, service startup, or microphone use.

The script grants `RECORD_AUDIO` and, where supported, `POST_NOTIFICATIONS` only
to `com.ores.sonus_auris.device_lab`. The device-lab package remains installed
but force-stopped after the run; its test removes all probe audio. Keeping the
package avoids using uninstall as an automated cleanup primitive and makes the
next in-place test repeatable.

## Run it from the complete Mac device lab

The existing iOS Simulator, physical iPhone, non-recording Android, Flutter
macOS, and evidence-policy checks remain available. Add the two recording
variables to opt into the isolated Android probe:

```bash
ANDROID_SERIAL=<authorized-adb-serial> \
SONUS_RUN_IOS_DEVICE=1 \
SONUS_RUN_ANDROID_DEVICE=1 \
SONUS_RUN_ANDROID_RECORDING_PROBE=1 \
SONUS_ANDROID_RECORDING_PROBE_CONSENT=I_CONSENT_TO_A_15_SECOND_SONUS_DEVICE_LAB_RECORDING \
  bash scripts/device-lab/macos-end-device-smoke.sh
```

A failure in one target does not prevent the remaining targets from collecting
evidence. The orchestrator returns nonzero when any attempted target or its
evidence policy fails.

## Evidence

Standalone runs write under:

```text
build/device-lab/android-recording-<UTC timestamp>/
```

Orchestrated runs place the probe under the parent run directory as
`android-recording-probe/`.

Shareable evidence contains only bounded metadata and diagnostics, including:

- a short hash of the ADB serial rather than the serial itself;
- Android SDK/security-patch metadata;
- the isolated APK digest and verified application ID;
- foreground-service, app-op, and isolated notification evidence;
- Flutter test output with segment count and in-memory PCM byte count; and
- explicit proofs that production was not addressed, shared logcat was not
  cleared, raw audio was not exported, and probe audio cleanup passed.

`scripts/device-lab/evidence-policy.py` sanitizes text, waits for writers to
close, rejects raw audio/key/provisioning artifacts and symlinks, and fails if a
recognized secret or local identifier remains.

## Hosted emulator gate

The device-lab workflow runs the same isolated package and Dart target on an API
34 KVM emulator with deterministic virtual microphone input. That hosted gate
proves build isolation, package verification, permission wiring, foreground
service behavior, Home/background recovery, WAV validation, cleanup, and
shareable evidence policy. It does not replace a run on the operator-owned
handset: real microphone hardware, OEM power management, USB transport, thermal
behavior, and the physical notification UI still require the command above.

## iPhone boundary

This Android probe does not make an iOS microphone claim. The existing iOS
Simulator and physical-iPhone harnesses remain install/update/launch/relaunch
checks without automated recording. A future iPhone real-microphone probe must
use an equally isolated bundle identifier, development signing, explicit consent,
and zero raw-audio evidence rather than reusing the production app sandbox.
