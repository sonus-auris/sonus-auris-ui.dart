# Disposable iOS Simulator microphone-permission denial lab

This lab verifies that Sonus Auris fails closed when iOS microphone access has
already been denied. It does not select or mutate the existing iOS Simulator
chosen in Xcode, and it never selects or mutates a physical iPhone.

The harness creates a new simulator, runs the denial test, verifies that the app
remains installed long enough to collect post-test evidence, and then deletes
only that test-created simulator.

## Isolation model

The app retains its normal Simulator bundle identifier:

```text
com.ores.audioDashcam
```

Isolation comes from the device boundary rather than rewriting the signed app:

1. The script selects a compatible available iOS runtime and an iPhone device
   type whose declared runtime range includes that version.
2. `simctl create` returns a new UUID owned by this run.
3. Every boot, install, privacy, log, container, terminate, shutdown, and delete
   command uses that exact UUID.
4. Existing simulators and physical iPhones may be enumerated by read-only
   discovery, but they are never selected as the target or mutated.
5. Flutter must discover the created UUID exactly once and classify it as an iOS
   emulator before the app is built.
6. The test-created simulator is deleted after evidence collection and also from
   an exit trap after failures or interruptions.

The script never runs `simctl erase`, never deletes all unavailable devices, and
never invokes `devicectl` or `ios-deploy`.

## Runtime compatibility

The hosted macOS image currently exposes both iOS 18.x and iOS 26.x runtimes.
The first implementation blindly selected iOS 26.2. Flutter 3.44.2 built the app
successfully but could not establish its debug/log connection to that runtime;
`flutter drive` reported a failed log reader and exhausted its launch retries.

The lab therefore defaults to the newest available iOS runtime at or below major
18:

```text
SONUS_IOS_PERMISSION_LAB_MAX_RUNTIME_MAJOR=18
```

This is a test-tool compatibility cap, not an application deployment limit. A
newer validated Flutter/Xcode combination can select another installed major
explicitly:

```bash
SONUS_IOS_PERMISSION_LAB_RUNTIME_MAJOR=26 \
  bash scripts/device-lab/ios-permission-denial-probe.sh
```

The script fails rather than silently selecting an incompatible runtime when the
requested major or a runtime under the cap is unavailable. It records the
selected runtime, major, version, selection policy, device type, and Flutter
visibility result in sanitized evidence.

## What it proves

After installing the integration candidate, the host runs:

```text
simctl privacy <test-created-uuid> revoke microphone com.ores.audioDashcam
```

The compile-time-gated Dart target then requires:

- `SegmentRecorder.start` to return within 30 seconds;
- an actionable error containing `permission`;
- recorder state to return to idle;
- recording never to start;
- no `.wav` file to exist;
- no `.part` file to exist; and
- test-owned storage cleanup to pass.

The host also requires:

- the result and cleanup markers from Flutter;
- `flutter drive --keep-app-running`;
- valid installed app containers before and after Flutter drive;
- no fatal process evidence in a bounded Simulator log; and
- successful deletion of the simulator created by this run.

A drive timeout or failed attach captures bounded Runner/SpringBoard logs before
the disposable simulator is removed. No raw audio is generated or exported.

## Run on the MacBook

From the Flutter repository root:

```bash
bash scripts/device-lab/ios-permission-denial-probe.sh
```

Prerequisites:

```bash
flutter doctor -v
xcodebuild -version
xcrun simctl list runtimes available
```

At least one compatible iOS Simulator runtime and one compatible iPhone device
type must be installed through Xcode Settings > Platforms. To change the default
compatibility cap or drive deadline:

```bash
SONUS_IOS_PERMISSION_LAB_MAX_RUNTIME_MAJOR=18 \
SONUS_IOS_PERMISSION_DRIVE_TIMEOUT_SECONDS=480 \
  bash scripts/device-lab/ios-permission-denial-probe.sh
```

The command does not need the real iPhone to be connected. Read-only Flutter
device discovery may enumerate a connected phone, but the script will not select
or mutate it.

## Run from the complete Mac device lab

The disposable denial lab is an independent opt-in target in the existing
one-command orchestrator:

```bash
ANDROID_SERIAL=<authorized-adb-serial> \
SONUS_RUN_IOS_SIMULATOR=1 \
SONUS_RUN_IOS_PERMISSION_DENIAL_PROBE=1 \
SONUS_RUN_IOS_DEVICE=1 \
SONUS_RUN_ANDROID_DEVICE=1 \
SONUS_RUN_ANDROID_PERMISSION_DENIAL_PROBE=1 \
SONUS_RUN_ANDROID_RECORDING_PROBE=1 \
SONUS_ANDROID_RECORDING_PROBE_CONSENT=I_CONSENT_TO_A_15_SECOND_SONUS_DEVICE_LAB_RECORDING \
  bash scripts/device-lab/macos-end-device-smoke.sh
```

This sequence keeps the targets separate:

- the ordinary iOS Simulator smoke preserves its existing data container;
- the iOS permission probe creates and deletes a different disposable Simulator;
- the paired iPhone receives only the non-recording install/launch/relaunch
  smoke;
- Android denial and recording use distinct debug-only application IDs; and
- every target writes a separate evidence directory under the parent run.

A failure in one attempted target is recorded without preventing the remaining
targets from collecting evidence. The orchestrator returns nonzero when any
attempted target or evidence-policy check fails.

## Evidence

Standalone runs write sanitized evidence under:

```text
build/device-lab/ios-permission-<UTC timestamp>/
```

Evidence contains only bounded metadata and diagnostics, including:

- a short hash of the test-created simulator UUID;
- selected runtime, compatibility policy, and device type;
- proof that Flutter saw one supported iOS emulator;
- relative app-bundle file hashes;
- pre-drive and post-drive app-container fingerprints;
- content-free Flutter result and cleanup markers;
- bounded success or failure process logs; and
- explicit statements that no existing simulator or physical iPhone was
  selected or mutated, no audio artifact existed, and the disposable simulator
  was deleted.

`scripts/device-lab/evidence-policy.py` sanitizes live output and stored text,
waits for writers to close, rejects raw audio/key/provisioning artifacts and
symlinks, and fails when recognized secrets or local identifiers remain.

## Hosted gate

`.github/workflows/ios-permission-lab.yml` runs the same script on `macos-15`,
sets the iOS 18 compatibility cap explicitly, checks its seven-group safety
contract on Linux first, formats the Dart target, and uploads evidence only after
the common evidence policy passes.

A hosted Simulator pass does not establish microphone-denial UI or operating
behavior on the real iPhone. Physical-device permission testing requires a
separately signed, isolated bundle and explicit operator interaction; this lab
intentionally does not alter the real phone's TCC state.
