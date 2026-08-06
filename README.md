> [!IMPORTANT]
> **Deprecated.** This Flutter recorder and its Git history have moved to
> [sonus-auris-flutter.dart](https://github.com/sonus-auris/sonus-auris-flutter.dart).
> Do not open new work or releases from this repository. Use the canonical
> Flutter repository for mobile, desktop, and recorder development.

# Audio Dashcam

Flutter Android/iOS app for continuous rolling audio capture. It keeps one microphone stream open, writes short overlapped `.wav` segments, keeps the most recent local window on-device, and uploads segments through either the sound-recorder backend or a direct S3-compatible fallback.

The recorder is the product core: a private audio dashcam for musicians,
note-takers, and people preserving contemporaneous context. Sleep estimates,
song identification, speech/keyword handling, and safety-sound cues are
opt-in/best-effort sidecars with bounded queues and timeouts; none may gate or
stop capture. Recording laws and consent requirements vary by jurisdiction,
and the app does not promise legal admissibility, prevent lawsuits, diagnose a
medical condition, or establish that an incident occurred.

## Defaults

- Local retention: 100 hours
- Cloud retention: 500 hours
- Segment length: 1 minute
- Overlap: 2 seconds at the start of every segment after the first
- Encoding: PCM16 `.wav`, mono, 16 kHz, about 256 kbps
- Provider support: the Rust backend can issue presigned upload URLs and fan out
  cloud copy jobs for S3, Google Drive, Microsoft OneDrive, Dropbox, and
  client-managed iCloud. Direct AWS S3 / Cloudflare R2 upload remains available
  from Connections without a Sonus Auris server account; its credentials stay
  in this device's secure credential store.
- UI: mobile has Home, Playback, Connections, Automation, and Configure. The
  Flutter desktop app has Home, Playback, Configure, Connections, and Devices
  in its right-side workspace rail plus a collapsible account rail.

## Storage Math

Audio size is controlled by bitrate. Continuous sample-accurate chunking currently records PCM16 WAV:

```text
bytes = bitrate_bits_per_second / 8 * seconds
```

At the default 16 kHz mono PCM16 setting:

- 1 minute is about 1.92 MB before the small WAV header and overlap overhead.
- 100 hours is about 11.52 GB.
- 500 hours is about 57.6 GB.

Compressed AAC at 64 kbps would be about 14.4 GB for 500 hours, but stop/start encoder file rotation cannot guarantee sample-continuous minute boundaries the way PCM stream chunking can.

## Runtime Notes

- Android uses a foreground microphone service while recording. The app asks for microphone and notification permission for core capture; location, Bluetooth, nearby-Wi-Fi, and motion capabilities remain separately disclosed and opt-in.
- On Android 11+, microphone capture must be started while the app is foregrounded. After the foreground microphone service is running, the app can move to the background and continue recording under the visible notification. A boot receiver re-arms user schedules, but the app does not try to auto-start microphone capture from boot or from a background-only state (Android 14+ does not permit a microphone foreground service to cold-start from `BOOT_COMPLETED`).
- Android app backup is disabled so app-local audio and cloud configuration are not copied into device backups.
- iOS uses microphone permission and the `audio` background mode. iOS will still stop capture if the user force-quits the app or the OS terminates it.
- Segment boundaries are sample-counted. Playback trims the duplicate overlap with `just_audio` clipping so local playback does not repeat the overlap.
- Local files are stored inside the app support directory. The segment index is written atomically, and corrupt index files are quarantined instead of crashing startup.
- The core 100-hour-or-shorter fail-closed retention path is merged: expired audio, known sidecars/partials, and registered derived artifacts are deleted even when backup is unavailable, with crash-replayable tombstones. DEN-250 still tracks complete worker registration, pre-expiry warning/export, privacy-dashboard evidence, and account-deletion/consent-revocation race tests.
- Segments persisted as `uploading` are retried on the next upload drain, so a crash during upload does not strand them forever.
- Backend uploads create a server upload session, presign each segment, PUT the encrypted object to the signed URL, then mark the segment complete.
- Permanent saves select indexed segments overlapping a playback timestamp range. Direct S3 saves write or copy segments under `<prefix>/<deviceId>/permanent/...`; backend providers use `POST /api/mobile/v1/permanent-saves` so the server can copy retained chunks into the provider's long-term location.
- Paid access for permanent saves should be enforced by the backend or billing entitlement layer. Gate or disable the direct S3 fallback in production if client-only S3 credentials would bypass that entitlement.
- Alert requests can ask the backend to email a listening link 20 seconds before a manual or commotion trigger. The app queues alerts until matching uploaded audio is available, and the backend rejects alerts that do not overlap uploaded retained segments. The backend exposes `POST /api/mobile/v1/alerts` and `/listen/:alert_id`.
- The backend and signed upload URLs must use HTTPS except for localhost development. Signed upload responses are accepted only for `PUT`, and unsafe signed headers are rejected.
- Direct AWS S3 uploads require HTTPS and lowercase DNS-safe bucket names using letters, numbers, and hyphens. Custom S3-compatible endpoints must also use HTTPS.
- S3 uploads and deletes time out instead of hanging the queue indefinitely.
- Backend device tokens, S3 access keys, secret keys, and session tokens are stored with Flutter Secure Storage using Android secure storage and non-migrating iOS keychain accessibility.
- For production, prefer temporary scoped credentials or a presigned-upload broker over long-lived AWS keys on the device.

## S3 IAM Shape

Use a bucket/prefix scoped principal. The app needs:

- `s3:PutObject` for uploads
- `s3:GetObject` on the rolling prefix and `s3:PutObject` on the permanent prefix for permanent saves copied from the rolling S3 window
- `s3:DeleteObject` for cloud retention deletion

If a later cloud playback browser needs listing, add `s3:ListBucket` scoped to the app prefix.

## Acoustic Intelligence (on-device FFT)

An optional frequency-domain engine runs alongside capture. It is **off by
default** (enable it under Configure → Acoustic Intelligence) and, when on, stays
idle until the input is sustained at or above an activation level (dBFS) for a
few seconds. A near-full-scale transient with a high peak/RMS crest opens the
gate immediately so a one-off crash or bang reaches the FFT. Once active it
keeps analyzing through quiet stretches for a hold window so gaps between
sounds are observed, then goes idle again.

- Analysis runs on a background isolate (`AcousticAnalyzer`) so the capture path
  never blocks. The recorder decimates the processed stream to ~16 kHz mono and
  feeds 2048-point Hann-windowed FFT frames (50% overlap). FFT uses `fftea`.
- Every frame includes spectral centroid/flatness/crest/rolloff and low, speech,
  and high-band energy, plus RMS/dBFS, peak amplitude, time-domain crest factor,
  and clipping fraction.
- Detectors (all pure/unit-tested in `lib/src/services/acoustic/`):
  - **Snoring** — sustained low-centroid bursts with strong 60–300 Hz energy.
  - **Possible apnea pattern** — a run of regular snores interrupted by a long
    cessation (>~10 s) that then resumes. **This is a non-diagnostic acoustic
    heuristic, not a medical diagnosis or a medical device.**
  - **Music** — sustained pitched/harmonic content with a steady beat (tempo
    from the loudness-envelope autocorrelation).
  - **Speech** — voiced-band (300–3400 Hz) dominance with 3–8 Hz syllabic
    modulation.
  - **Sudden loud noise** — rapid level rise plus transient or broadband
    evidence. This does not claim an accident or its cause.
  - **Raised voice / possible argument pattern** — sustained loud speech-band
    energy, with a possible-pattern event only after three distinct bursts.
    This does not prove an argument, speaker count, or identity.
- **Song identification (ShazamKit, iOS only):** when music is detected and the
  user enables it, a short clip is matched with Apple's ShazamKit via the
  `audio_dashcam/shazam` platform channel. Requires the ShazamKit capability on
  the App ID (see entitlements). On Android the event still says "music
  detected" but carries no title. Only a derived audio signature is sent.
- **User-defined keywords and safety words:** when speech is detected and
  recognition phrases are configured, on-device transcription is tried first.
  Cloud STT is an explicit fallback opt-in. Safety words are tracked separately
  and take priority when lists overlap. A match dings, records a `keyword` event
  with its phrase type, raises the existing alert/email, and forces
  full-fidelity recording for the user-selected 15–360 minute window (90
  minutes by default). Clear speech temporarily keeps adaptive storage at full
  quality; quiet periods return to the low-storage profile.
- **Possible collision reminder (opt-in motion sensor):** while recording, a conservative
  gravity-filtered accelerometer spike shows a local notification and ding to
  remind the user that the moment is in the rolling buffer. It is only a hint,
  never an emergency-service trigger or a claim that a crash occurred.
- Classification and feature extraction happen on-device; no transcription is
  needed for these classes. Detection metadata is surfaced on the Home screen
  and follows the configured Supabase sync.
- Every finalized WAV gets a versioned `<stem>.features.json` track with aligned
  FFT frames and a compact heuristic summary. Direct S3 sync uploads it beside
  the audio and encrypts it independently. Backend sync attaches only the
  compact summary to the segment metadata.

## Adaptive Recording Quality

When enabled, the microphone always opens at the high `captureSampleRate` (so the
FFT engine and sample-continuous timeline are preserved), but each one-minute
segment is stored at full quality only when its trailing loudness is at or above
the loud/quiet threshold; quiet segments are anti-aliased and decimated to
`quietSampleRate` before being written. Stored rate is per-segment
(`RecordingSegment.sampleRate`), and wall-clock segment timestamps stay
authoritative, so playback and ranges are unaffected. Clear speech holds full
quality briefly; a configured keyword or safety-word match holds it for the
selected phrase window.

## Passwordless Supabase accounts

Every native/mobile sign-up and sign-in surface is code-first: it sends a
six-digit Supabase email OTP, and unknown email addresses are created on first
verification. The app has no account password field or password-reset flow.
The same email retains a magic-link fallback using S256 PKCE: the callback
contains only a one-time authorization code, while the matching verifier stays
in Keychain/Keystore and expires with the request. Release clients reject
access or refresh tokens delivered in a callback URL. Add
`sonusauris://auth/callback` (or the
`SONUS_SUPABASE_AUTH_REDIRECT_URL` build-time override) to the Supabase Auth
redirect allow-list as an exact URL. The hosted Magic Link template must retain
both `{{ .ConfirmationURL }}` and the six-digit `{{ .Token }}` fallback.

For local development while Supabase is unavailable, a debug build can expose
the explicit offline option with
`--dart-define=SONUS_ENABLE_OFFLINE_MODE=true`. The override is compiled out of
release builds, does not create an account or cloud identity, and leaves local
recording, playback, schedules, iCloud mirroring, and direct S3/R2 available.
Account initialization runs in the background so an unreachable Supabase
instance cannot hold the app at its startup spinner.

Google Drive, OneDrive, and Dropbox linking returns through the backend's
hosted `/oauth/callback` and immediately into the waiting app session, so users
do not need to locate or paste authorization codes. Register that exact hosted
HTTPS callback in each provider console. iCloud uses the signed Apple container
on the device and can mirror recordings in addition to another linked cloud
destination.

macOS developer/notarized builds use the minimal
`Runner/Release.entitlements` so they remain buildable without an Apple
provisioning profile. A Mac App Store archive that enables the signed iCloud
Documents container is produced with
`scripts/release/macos-archive-store.sh`; it requires
`APPLE_DEVELOPMENT_TEAM`, an Apple Distribution identity, and a profile that
authorizes `iCloud.com.ores.audioDashcam`.

## Supabase Schema (acoustic_events)

Detection events are user data and are written to Supabase via PostgREST using
the signed-in user's access token (never a service key); row-level security
scopes every row to that user. The audio files themselves still go to S3 /
Google Drive / the backend as before. Create the table once:

```sql
create table public.acoustic_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id),
  device_id   text not null,
  kind        text not null,
  started_at  timestamptz not null,
  ended_at    timestamptz not null,
  confidence  double precision not null default 0,
  details     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);

alter table public.acoustic_events enable row level security;
create policy "own rows: insert" on public.acoustic_events
  for insert with check (user_id = auth.uid());
create policy "own rows: select" on public.acoustic_events
  for select using (user_id = auth.uid());
```

The client sends `device_id, kind, started_at, ended_at, confidence, details`;
`user_id` defaults to `auth.uid()` server-side.

## Development

Flutter was installed locally at:

```sh
/Users/maca5/development/flutter
```

Run checks:

```sh
/Users/maca5/development/flutter/bin/flutter analyze
/Users/maca5/development/flutter/bin/flutter test
```

The opt-in live Supabase test uses three independent, fresh email codes: one
identity exercises the rendered passwordless sign-in UI, while two separate
identities insert one `acoustic_events` fixture each, prove cross-user reads and
writes are blocked by RLS, and remove both fixtures:

```sh
flutter test -d macos integration_test/live_supabase_auth_test.dart \
  --dart-define=SONUS_SUPABASE_URL=https://PROJECT.supabase.co \
  --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_REPLACE_ME \
  --dart-define=SONUS_TEST_EMAIL=user-a@example.test \
  --dart-define=SONUS_TEST_EMAIL_OTP=REPLACE_WITH_FRESH_CODE \
  --dart-define=SONUS_TEST_EMAIL_B=user-b@example.test \
  --dart-define=SONUS_TEST_EMAIL_OTP_B=REPLACE_WITH_FRESH_CODE
```

Use only the public client key. The test never accepts a service-role key and
does not print access tokens. To include the rendered UI leg, use the local
Supabase harness below; it reads the fresh UI code from local Mailpit after the
app itself requests it:

```sh
scripts/e2e/local-supabase-auth.mjs
```

Run on a configured device:

```sh
/Users/maca5/development/flutter/bin/flutter run
```

When hosted Supabase is temporarily unavailable, developers can explicitly run
the local-only recorder path:

```sh
flutter run --dart-define=SONUS_ENABLE_OFFLINE_MODE=true
```

This override is rejected by release builds. It never fabricates a user,
device registration, entitlement, or cloud connection; those features remain
disabled until a real passwordless sign-in succeeds.

Install on a physical Android phone over Wi-Fi:

- Enable Developer options and Wireless debugging on the phone.
- Pair once with `adb pair PHONE_PAIRING_IP:PORT` using the 6-digit pairing code.
- Connect with `adb connect PHONE_ADB_IP:PORT`.
- Build/install with `/Users/maca5/development/flutter/bin/flutter install -d PHONE_ADB_IP:PORT`.

Being on the same Wi-Fi is not enough by itself; Android requires ADB authorization.

Android SDK/JDK are configured on this machine. iOS still needs full Xcode plus CocoaPods before local iOS builds can be verified.

### CLI flags

[`flags-2-env`](https://github.com/ORESoftware/flags-2-env) validates the public
backend, Supabase, and OAuth build settings before invoking Flutter tooling:

```sh
scripts/with-flags help
scripts/with-flags audit
scripts/with-flags \
  --backend-base-url=https://api.example.test \
  --supabase-url=https://project.supabase.co \
  --supabase-anon-key=sb_publishable_example \
  -- scripts/release/android-build-aab.sh
```

The release scripts already translate these environment values into
`--dart-define` arguments. Only public client configuration belongs here; never
pass a Supabase service-role key. The wrapper uses the monorepo's pinned native
source or the executable named by `FLAGS2ENV_BIN`.

## Desktop builds (macOS / Windows / Linux)

This same codebase is also a **Flutter desktop app** — Flutter compiles to native
machine code (macOS ARM64/x86-64, Windows EXE, Linux ELF). Desktop targets are
enabled and the `macos/`, `windows/`, and `linux/` runners are scaffolded.

The desktop build has its **own entrypoint** — `lib/main_desktop.dart` — separate
from the phone's `lib/main.dart`. Both share the entire core (`AppController`,
services, crypto, models) but present independent UIs and can diverge in logic:
the phone records this device with a touch UI; the desktop uses a windowed
nav-rail layout, records the selected built-in/USB/Bluetooth microphone, and
includes the account's Devices view.
Form factor / role helpers live in `lib/src/platform/form_factor.dart`.

```sh
flutter config --enable-macos-desktop --enable-windows-desktop --enable-linux-desktop
flutter run   -d macos   -t lib/main_desktop.dart      # or: -d windows / -d linux
flutter build macos      -t lib/main_desktop.dart      # needs full Xcode; Windows → Visual Studio; Linux → GTK/clang/ninja
```

Plugin notes on desktop: mobile-only plugins (e.g. `flutter_foreground_task`,
foreground capture) are simply not registered on desktop and the code already
guards them with `Platform.isAndroid`, so they no-op. `flutter_web_auth_2`
(OAuth) pulls `desktop_webview_window` on desktop. The desktop Connections view
can configure direct S3/R2 while signed out; account-linked OAuth providers
appear after passwordless sign-in and device registration.

> This is the **Flutter** desktop app. There is also a separate, lean **pure-Rust**
> desktop recorder in the `desktop.app.rs` repo — two desktop apps by design.

## Emulator Validation

An Android API 36 ARM64 emulator named `audio_dashcam_api36` was created with microphone input enabled.

Verified on that emulator:

- Debug APK builds and installs.
- `RECORD_AUDIO`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_MICROPHONE` are declared/granted.
- Starting capture from the foreground creates an Android foreground service with microphone type `0x00000080`.
- After sending the app Home, the foreground service remained alive past multiple one-minute segment rotations, and Android app-ops reported `RECORD_AUDIO` running.
- `.wav` segment files were written under the app sandbox. The first one-minute file was 1,920,044 bytes; the second file was 1,984,044 bytes because it includes the configured 2-second overlap.
- `segments.v1.json` was updated with sample timeline metadata: sequence 0 ended at sample 960000, sequence 1 started at sample 960000, and sequence 1 stored 32000 overlap samples.
- Stopping recording finalized the active `.wav.part` file and removed the foreground service.

Observed emulator limitation:

- The Android emulator audio HAL logged repeated `pcm_readi` I/O errors. Android's own MediaRecorder documentation says emulator audio recording is not a substitute for a real recording device, so final audio-quality validation still needs a physical Android phone.
