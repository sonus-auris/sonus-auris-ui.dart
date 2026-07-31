# Sonus Auris — Privacy Policy

_Last updated: <SET DATE>. Publisher: <LEGAL ENTITY NAME>, contact: <privacy@yourdomain>._

> This draft is written to match how the app actually behaves. Review the
> bracketed `<…>` placeholders, have counsel review it, host it at a stable public
> URL, and keep that published version synchronized with every shipped build and
> store disclosure.

## Summary

Sonus Auris records audio only after you start recording, accept a recording
prompt, or explicitly arm a recording schedule. A rolling working window can
remain plaintext inside the app-private storage on your device for up to **100
hours**, or a shorter period you configure, so approved local analysis can run.
Every backup or cross-device-sync object is encrypted on your device before it
leaves (AES-256-GCM). Ciphertext can be sent to storage **you** connect (your
own S3 bucket, Google Drive, OneDrive, or Dropbox) or to Sonus Auris backup
storage; the encryption keys stay on your device, so the Sonus Auris backend and
ordinary object-storage providers receive ciphertext and cannot decrypt it. For
iCloud Drive, your Apple device decrypts the recording locally into your own
iCloud Drive so the file remains usable there; Sonus Auris servers still do not
receive the plaintext.

A schedule records your intent, but it cannot override iOS or Android lifecycle
rules. Force-quitting, force-stopping, or operating-system termination can prevent
a future scheduled start until you reopen the app. While recording is active,
Android shows a persistent notification and iOS shows its system microphone
indicator.

## What we collect and why

**Audio recordings** — created only after an explicit Start action, accepted
prompt, or armed schedule. The app keeps a rolling working window in app-private
local storage for up to 100 hours or your selected shorter period. That local
working audio may be plaintext so the app can record, play, transcribe, and
analyze it. Purpose: the core recording and user-selected analysis features.
>>>>>>> origin/main

**Encrypted backups and device sync** — if you enable backup or sync, each audio
object is encrypted on-device with a fresh per-object key before upload. The
object key is wrapped only for authorized device/account recipients. Purpose:
backup, restoration, and access from your authorized devices.

**Optional location** — OFF by default. If you enable geotagging, approximate or
precise location at capture time can be attached to a clip. Purpose: app
functionality you opt into.

**Optional external audio analysis** — OFF by default. Core sleep/snore,
music-pattern, speech-pattern, and loud-event detectors run locally on your
device. If you separately enable and configure an external speech-to-text,
song-recognition, or similar service, the audio excerpt needed for that request
is sent to that provider under its terms. Sonus Auris discloses this before the
feature is enabled; recognition is not required for recording.

**Optional local audio analysis** — configurable analysis can identify music,
produce meeting notes, detect non-diagnostic sleep/snore patterns, mark loud or
raised-voice events, and provide diction, pacing, filler-word, pronunciation, or
word-choice suggestions. Derived results can include transcripts, summaries,
tasks, labels, and confidence scores. These features do not prove identity,
intent, an altercation, a medical condition, legal facts, or perfect accuracy.

**Optional external processing** — some features can send a user-selected or
minimum necessary clip, transcript, signature, or derived data to a service you
configure or explicitly enable, such as speech-to-text or music identification.
The app must identify the destination before sending data. That provider's terms,
retention, and privacy practices apply. Raw audio is not sent to an external AI
or transcription service by default.

**Account / backend data** — if you use an account, we process your email address,
user and device identifiers, authentication/session data, authorized-device
public keys, consent records, settings, encrypted-object metadata, timestamps,
sizes, hashes, upload state, retention/deletion state, and sync manifests.
Purpose: authentication, encrypted backup/sync, device authorization, deletion,
and features you request.

**Diagnostics** — after sign-in, sanitized app events, errors, stack traces,
platform, app version, and operation state can be sent to our Supabase project
under your user/device ID. Secret-shaped fields are redacted. Diagnostics must
not contain audio content, transcripts, private keys, object keys, tokens, or
user-entered notes. We do not bundle advertising SDKs.

## What we do not do

- We do not sell your data.
<<<<<<< HEAD
- We do not use your data for advertising.
- We do not have access to the contents of recordings sealed for Sonus Auris or
  supported connected-storage backup. Copies you direct to iCloud Drive are
  decrypted locally by your Apple device and governed by your Apple account.
- We do not record unless you start capture or explicitly arm a recording schedule.

## Where your data goes

- **On your device** by default, inside private OS-protected app storage.
- **To storage you control**, if you connect it (your S3-compatible bucket,
  Google Drive, OneDrive, Dropbox, or iCloud). Supported outbound backups are
  sealed on-device before transfer, except that iCloud copies are decrypted
  locally into your own iCloud Drive so they remain usable there. Each
  provider's handling is governed by its terms.
- **To Supabase and the optional Sonus Auris backend**, only for features you
  invoke (authentication, settings/consent sync, diagnostics, backup
  coordination, encrypted backup, and alert links). Recordings remain
  client-encrypted; the services cannot derive the device-held key.
- **To an external recognition provider**, only when you explicitly enable and
  invoke a feature that needs it. The provider receives the bounded audio excerpt
  required for that request; connected-storage encryption does not apply to an
  excerpt deliberately sent for recognition.
=======
- We do not use your data for advertising or cross-app tracking.
- We do not record until you start, accept a prompt, or explicitly arm a schedule.
- We do not claim that a schedule can bypass force-quit, force-stop, permission,
  or operating-system restrictions.
- We cannot decrypt ordinary encrypted backup/sync objects because the required
  private keys remain on authorized client devices or in user-controlled recovery.
- We do not send raw audio to external AI/transcription services by default.

## Where your data goes

- **On your device:** the app-private rolling working window, local analysis,
  playback, temporary analysis artifacts, settings, and secure key material.
- **To storage you connect:** encrypted objects can go to your S3-compatible
  bucket, Google Drive, OneDrive, iCloud, or another supported destination.
- **To Supabase and the Sonus Auris backend:** account/auth data, consent/settings,
  authorized-device public keys, diagnostics, encrypted backup/sync objects or
  coordination metadata, and features you request.
- **To an optional processing provider:** only when you explicitly enable a
  feature that needs it; the app sends the minimum declared data for that feature.
>>>>>>> origin/main

## Retention

The local working audio window ages out automatically at **100 hours by default**
or your selected shorter period. The app must also remove expired partial files,
temporary clips, caches, sidecars, transcripts, and analysis scratch data. You
can shorten retention, stop recording, disable analysis, or delete the local
window.

Failed, disabled, or offline backup must not silently extend plaintext retention
past the configured 100-hour-or-shorter ceiling. The app should warn you before
an unbacked local copy expires and give you an explicit save/export opportunity.

Encrypted backups persist according to the configured destination/plan until
their retention expires or you delete them. Derived transcripts, summaries,
detections, and annotations have their own visible retention/deletion controls.
Account deletion removes backend ciphertext and metadata subject to narrowly
required legal/security retention documented at the time of deletion.

## Your choices and rights

- Start, pause, or stop recording at any time.
- Arm, edit, or disable schedules and see whether the app is armed or recording.
- Shorten local retention and delete the current local window.
- Turn each optional analysis, location, context-trigger, backup, device-sync, or
  external-processing feature on or off.
- Review and revoke authorized devices; revoked devices must not receive keys for
  newly created audio.
- Export or delete clips, transcripts, summaries, and account data.
- Delete your account in-app and through the public account-deletion page.
- Exercise applicable regional access, correction, portability, restriction,
  objection, or deletion rights by contacting us.

## Children

Sonus Auris is not directed to children under 13 or the applicable minimum age in
your country, and we do not knowingly collect their data.

## Security

<<<<<<< HEAD
Local rolling files remain inside private, OS-protected app storage. Recordings
are sealed on-device before supported cloud upload; transport uses TLS/HTTPS.
Tokens and keys are stored using platform secure storage (iOS Keychain /
Android Keystore). iCloud copies are decrypted locally into the user's own
iCloud Drive and never pass through Sonus Auris servers as plaintext.
=======
Local working audio is isolated in the app-private sandbox and excluded from app
backup, but it may be plaintext during the configured rolling period. Every
outbound backup/sync audio object is encrypted on-device using authenticated
envelope encryption. Private keys and tokens use platform secure storage (iOS
Keychain / Android Keystore), and network transport uses TLS/HTTPS.

No system can eliminate all risk. A person who can unlock or compromise your
device may be able to access the local working window while it exists. Use device
lock, current operating-system updates, a shorter retention setting when
appropriate, and account/device-revocation controls.
>>>>>>> origin/main

## Recording responsibly

You are responsible for complying with recording, consent, privacy, employment,
and other laws that apply to you and the people around you. Sonus Auris is not a
covert-surveillance tool. Do not use sleep, altercation, diction, transcription,
or other analysis as a medical diagnosis, emergency service, legal conclusion,
or guaranteed account of events.

## Changes

We will update this policy as the app evolves, revise the "Last updated" date,
and request renewed consent when a material recording or processing disclosure
changes.

## Contact

<LEGAL ENTITY NAME>, <postal address>, <privacy@yourdomain>.
