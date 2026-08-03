# Sonus Auris end-device testing

This is the operator runbook for testing the Flutter mobile app, the Flutter
macOS app, and the pure-Rust macOS app on the hardware currently attached to a
MacBook. It complements hosted CI; it does not replace signed TestFlight, Play
internal-track, notarization, or long-duration endurance acceptance.

Tracked by Linear issue **DEN-1398**. The longer mobile endurance matrix remains
in **DEN-296**, and the current Samsung release-candidate acceptance remains in
**DEN-836**.

## Available target matrix

| Target | Transport | Automated evidence | Manual evidence still required |
|---|---|---|---|
| iOS Simulator | CoreSimulator on the MacBook | build, install, launch, process health, PID-scoped crash logs, cold relaunch, in-place reinstall, data-container preservation, post-update relaunch, optional screenshots | microphone/background restrictions that the simulator cannot represent faithfully |
| Physical iPhone | USB for first pairing, then USB or paired Wi-Fi | development-signed install/update, two bounded launch cycles by default, sanitized Flutter/Xcode output | microphone prompt, recording indicator, lock/background capture, playback, Bluetooth changes, battery/thermal/storage observations |
| Physical Android | authorized USB ADB | non-destructive install/update, pre/post package-state comparison, launch, process/UI health, Home/foreground resume, time-bounded crash logs without clearing logcat, force-stop and cold relaunch | disclosure-driven permission prompts, recording notification/indicator, lock/background capture, playback, Bluetooth changes, battery/thermal/storage observations |
| Flutter macOS | isolated packaged `.app` | production bundle/signature verification, side-effect-suppressed isolated launch, crash-focused unified log, bounded app-event Quit | microphone grant and a short explicitly consented recording in the normal app |
| Rust macOS | packaged `.app` plus device probe in `desktop.app.rs` | CoreAudio enumeration/repeatability, isolated-data bundle launch/Quit, optional explicitly consented bounded WAV probe | microphone grant and comparison with the Flutter desktop result |

## Safety contract

The scripts under `scripts/device-lab/` are safe for operator-owned hardware by
default:

- no `adb uninstall`, `pm clear`, simulator erase, simulator uninstall, or device
  reset;
- no clearing of the physical Android device-wide logcat buffer;
- no automatic grant or revocation of microphone, notification, location,
  Bluetooth, nearby-Wi-Fi, or other sensitive permissions;
- no automated audio recording on mobile;
- no raw audio, OTP, token, credential, private key, provisioning profile, or
  recovery-code evidence;
- screenshots are off by default on operator devices because a signed-in screen
  may contain personal information;
- an APK signature mismatch fails closed rather than uninstalling the existing
  Android app and deleting app-private recordings, keys, settings, or account
  state; and
- desktop runtime probes refuse to disturb an already running normal app and use
  isolated settings/data domains so previous consent cannot silently resume
  recording.

The orchestrator runs `scripts/device-lab/evidence-policy.py` after every target.
That policy redacts local account paths, email addresses, tokens, callback/VM
service URLs, and common API-key forms; rejects raw-audio/key/provisioning files
and symlinks; and writes `evidence-policy.txt` into each target directory. A
target fails when its evidence fails this policy.

`scripts/emulator/permission-smoke.sh` intentionally performs a clean install and
mutates permissions. It remains **emulator-only** and must not be substituted for
the attached-device harness.

## MacBook prerequisites

Install current Xcode, Flutter, Android platform tools, CocoaPods, and Rust. Then
confirm the local toolchains and device visibility:

```bash
xcodebuild -version
flutter doctor -v
flutter devices
xcrun simctl list devices available
adb devices -l
cargo --version
```

For the physical iPhone, first connect by USB, unlock the phone, tap **Trust**,
enable **Developer Mode**, and wait for Xcode > Window > Devices and Simulators
to show it as ready. Paired Wi-Fi deployment can be used afterward while the
MacBook and iPhone are on the same network. The initial trust/development-signing
handshake should still be completed over USB.

For Android, enable Developer options and USB debugging, connect the cable,
unlock the handset, and approve the MacBook's RSA fingerprint. `adb devices`
must report `device`, not `unauthorized` or `offline`.

For local physical-iPhone builds, open `ios/Runner.xcworkspace` once and select a
valid Apple development team for the Runner target. The device must be included
in the development provisioning path. This is separate from App Store
distribution signing used by the protected release workflow.

## Run the complete Mac device lab

From `sonus-auris-ui.dart`:

```bash
SONUS_RUN_IOS_DEVICE=1 \
SONUS_RUN_ANDROID_DEVICE=1 \
  bash scripts/device-lab/macos-end-device-smoke.sh
```

The scripts are invoked through Bash deliberately, so the runbook remains valid
whether a checkout preserves executable mode bits or not.

The orchestrator runs the iOS Simulator and packaged Flutter macOS checks. It
also requires the paired physical iPhone and authorized USB Android target in
the command above. Every target receives its own evidence directory below:

```text
build/device-lab/run-<UTC timestamp>/
```

A failure on one target does not prevent the remaining targets from collecting
evidence. The command exits nonzero when any attempted target or evidence-policy
check fails.

### Automatic and explicit target selection

Without the two `SONUS_RUN_*` requirements, physical targets use `auto` mode and
are skipped when absent:

```bash
bash scripts/device-lab/macos-end-device-smoke.sh
```

When multiple targets of one type are visible, select the intended devices
explicitly instead of accepting an arbitrary target:

```bash
IOS_DEVICE_ID=<flutter-physical-iphone-id> \
ANDROID_SERIAL=<adb-serial> \
SONUS_RUN_IOS_DEVICE=1 \
SONUS_RUN_ANDROID_DEVICE=1 \
  bash scripts/device-lab/macos-end-device-smoke.sh
```

Other useful selections:

```bash
# Simulator + desktop only.
SONUS_RUN_IOS_DEVICE=0 \
SONUS_RUN_ANDROID_DEVICE=0 \
  bash scripts/device-lab/macos-end-device-smoke.sh

# Capture screenshots only after confirming the visible screens contain no
# private account data, OTPs, tokens, or recording content.
SONUS_CAPTURE_SCREENSHOT=1 \
  bash scripts/device-lab/macos-end-device-smoke.sh
```

## Run one target

### iOS Simulator

```bash
bash scripts/device-lab/ios-simulator-smoke.sh

# Or select a specific simulator UDID shown by `xcrun simctl list`.
bash scripts/device-lab/ios-simulator-smoke.sh <simulator-udid>
```

The script preserves installed app data. It builds a debug simulator app with
inert compile-only endpoints, installs it, launches it, verifies that the process
stays alive, captures sanitized logs scoped to the PID returned by
`simctl launch`, terminates the process, and cold-relaunches it. It then installs
the same candidate in place, compares only hashed data-container paths before
and after the update, and requires a healthy post-update relaunch. It never reads
app-private files to make the preservation claim.

First-launch, cold-relaunch, and post-update logs remain separate so a later phase
cannot overwrite earlier evidence. The same script runs on `macos-15` in
`.github/workflows/device-lab.yml`, giving pull requests a simulator runtime and
upgrade-preservation gate in addition to the existing unsigned iPhone compile.

### Physical iPhone

```bash
bash scripts/device-lab/ios-attached-smoke.sh

# Or name the Flutter device ID explicitly.
IOS_DEVICE_ID=<flutter-device-id> \
  bash scripts/device-lab/ios-attached-smoke.sh
```

The script uses normal Flutter/Xcode development signing. It installs/updates
without clearing app data, waits for a successful live launch, keeps the app
attached briefly, and exits through Flutter's normal quit path. It repeats this
bounded launch by default to catch a cold-relaunch regression while preserving
installed data and permission state. Set `SONUS_IOS_LAUNCH_CYCLES=1`, `2`, or `3`
when a different bounded count is needed.

All Flutter/pub/Xcode output is sanitized before evidence is written, including
local account paths, email addresses, VM-service authentication material,
callback parameters, and token-shaped values.

A successful launch/relaunch is not yet a microphone acceptance claim. On the
phone, explicitly verify:

1. the permission prompt names **Sonus Auris**;
2. recording begins only after consent and shows the iOS microphone indicator;
3. a short segment finalizes and plays back;
4. lock/background behavior matches the current disclosure and entitlement;
5. denied permission produces a recoverable, truthful UI rather than hidden
   capture or a crash;
6. Bluetooth/headset disconnect and reconnect do not silently select an
   unintended input;
7. no upload occurs before encryption; and
8. app version/build, battery, thermal, storage, and sanitized failure notes are
   recorded without attaching raw audio.

### Physical Android over USB

```bash
bash scripts/device-lab/android-attached-smoke.sh

# Explicit APK and adb target when several physical devices are connected.
bash scripts/device-lab/android-attached-smoke.sh \
  /path/to/app-release-or-debug.apk \
  <adb-serial>
```

When no APK path is supplied and the default debug APK is absent, the script
builds a local debug candidate with inert compile-only endpoints. For signed
release acceptance, pass the checksum-verified APK from the protected workflow
instead. The script never resolves a certificate mismatch by uninstalling the
existing package.

For an existing installation, the harness snapshots only `firstInstallTime` and
runtime permission grant booleans before `adb install -r`, then verifies those
values remain unchanged after the update. This is evidence that the harness did
not replace the package or mutate existing permission grants; it does not inspect
recordings, keys, settings, databases, or other app-private files. The checksum
evidence records the APK digest and basename only, never the Mac checkout path.

The attached-device harness excludes emulator targets by both serial and runtime
properties. Its lifecycle scope is install/update, first launch, process health,
non-sensitive UI semantics when exposed, Home/background then foreground resume,
crash-focused logs since each launch without clearing shared logcat, force-stop,
and cold relaunch. It records whether the process survived Home but requires
healthy foreground recovery either way. It does not touch permission state.
Complete the disclosure/recording/background/playback checks from DEN-836
manually on the handset.

### Packaged Flutter macOS app

```bash
bash scripts/device-lab/flutter-macos-smoke.sh
```

This builds `lib/main_desktop.dart` as a release `.app` and first verifies the
production identity `app.sonusauris.audioDashcam`. It then copies and re-signs a
test-owned bundle as `app.sonusauris.audioDashcam.deviceLab`, compiles with
`SONUS_DEVICE_LAB_NO_SIDE_EFFECTS=true`, and refuses to proceed while another
Flutter Sonus Auris desktop process is running. The isolated identity prevents
production SharedPreferences/TCC state from silently reusing stored recording
consent, while the compile-time flag suppresses login-item setup and migration.

The script launches that isolated bundle through LaunchServices rather than a
Terminal-owned Dart executable, inspects sanitized PID-scoped unified logs,
sends Quit only to the isolated bundle ID, and fails when its process remains
alive beyond the bounded shutdown window.

macOS may request Automation permission for the terminal to send the Quit event.
Grant it for the test terminal. Setting `SONUS_REQUIRE_APPLE_EVENT_QUIT=0` is
reserved for constrained CI diagnostics and is not acceptable evidence for the
explicit-Quit regression.

## Rust desktop companion

The Rust desktop repository contains its paired runbook and probe:

```bash
cd ../desktop.app.rs
bash scripts/device-lab/macos-runtime-smoke.sh
```

By default it enumerates CoreAudio inputs and exercises the packaged Rust app's
launch/Quit path without recording. Its hosted macOS job enumerates twice and
requires stable fingerprints/default-device metadata while ensuring raw device
names are absent. A bounded microphone probe requires both an explicit consent
flag and duration:

```bash
SONUS_DEVICE_PROBE_CONSENT=1 \
SONUS_DEVICE_PROBE_RECORD_SECONDS=5 \
  bash scripts/device-lab/macos-runtime-smoke.sh
```

The WAV remains outside the shareable evidence directory. Run the Rust and
Flutter desktop probes against the same selected microphone and compare input,
sample rate, visible indicator, finalized-file behavior, and bounded Quit.

## Evidence handling

Attach only the smallest sanitized evidence needed to DEN-1398/DEN-836/DEN-296:

- app version/build/commit and artifact checksum;
- hashed target identifier plus model/OS/runtime;
- install/update outcome and package/data-container preservation result;
- pass/fail lifecycle result;
- package permission state without changing it;
- crash-focused logs with tokens redacted;
- screenshots only after visual review; and
- manual battery, thermal, storage, Bluetooth, background, and playback notes.

Never attach raw audio, transcripts, account email/phone, OTPs, session or
refresh tokens, recovery codes, encryption keys, local full paths containing a
username, or an unreviewed full device/system log.
