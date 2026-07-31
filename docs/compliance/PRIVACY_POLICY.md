# Sonus Auris — Privacy Policy

_Last updated: <SET DATE>. Publisher: <LEGAL ENTITY NAME>, contact: <privacy@yourdomain>._

> This draft is written to match how the app actually behaves. Review the
> bracketed `<…>` placeholders, have counsel review if needed, then host it at a
> stable public URL (e.g. on the Sonus Auris website / GitHub Pages) and enter
> that URL in the App Store and Play Console. Both stores require a reachable
> privacy policy URL.

## Summary

Sonus Auris records audio you choose to capture. The rolling local files remain
inside the app's private, OS-protected storage. Before supported cloud backup
leaves the device, recordings are sealed on-device with AES-256-GCM. Ciphertext
can be sent to storage **you** connect (your own S3 bucket, Google Drive,
OneDrive, or Dropbox) or to Sonus Auris backup storage. The encryption keys stay
on your device, so Sonus Auris servers cannot listen to those backups. For
iCloud Drive, your Apple device decrypts the recording locally into your own
iCloud Drive so the file remains usable there; Sonus Auris servers still do not
receive the plaintext.

## What we collect and why

**Audio recordings** — created only after you tap Start or explicitly arm a
recording schedule. Stored locally as a rolling window in the app's private,
OS-protected storage. Before supported cloud transfer, recordings are sealed
on-device with AES-256-GCM using device-held key material. Purpose: the core
recording feature.

**Optional location** — OFF by default. If you enable geotagging, the approximate
or precise location at capture time is attached to a clip so you can prove where
it was recorded. Purpose: app functionality you opt into.

**Optional audio analysis** — OFF by default. Core sleep/snore, music-pattern,
speech-pattern, and loud-event detectors run locally on your device. If you
separately enable and configure an external speech-to-text, song-recognition, or
similar service, the audio excerpt needed for that request is sent to that
provider under its terms. Sonus Auris discloses this before the feature is
enabled; recognition is not required for recording.

**Account / backend data (only if you use an account)** — your email address, a
user and device identifier, authentication tokens, and metadata about clips you
choose to back up or share (timestamps, sizes, upload status). Purpose:
authentication, backup coordination, and optional alert/listening links you request.

**Diagnostics** — after you sign in, sanitized app events, errors, stack traces,
platform, and app version can be sent to our Supabase project under your user and
device ID so we can operate and fix the app. Secret-shaped fields are redacted;
diagnostics do not contain recording audio. We do not include third-party
advertising or analytics SDKs.

## What we do NOT do

- We do not sell your data.
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

## Retention

Local clips age out automatically based on your rolling-window setting. Backed-up
clips persist according to the retention settings for their destination or until
you delete them. Backend ciphertext and metadata are removed when their retention
expires or on account deletion, subject to the limited legal retention below.

## Your choices and rights

- Start/stop recording at any time; delete any clip in the app.
- Turn location, analysis, and backup on or off at any time.
- **Delete your account and associated data** — see ACCOUNT_DELETION (linked
  in-app and on our website). Depending on your region (e.g. GDPR/CCPA), you may
  also request access to or export of data we hold; contact us below.

## Children

Sonus Auris is not directed to children under 13 (or the minimum age in your
country) and we do not knowingly collect their data.

## Security

Local rolling files remain inside private, OS-protected app storage. Recordings
are sealed on-device before supported cloud upload; transport uses TLS/HTTPS.
Tokens and keys are stored using platform secure storage (iOS Keychain /
Android Keystore). iCloud copies are decrypted locally into the user's own
iCloud Drive and never pass through Sonus Auris servers as plaintext.

## Recording responsibly

You are responsible for complying with the audio-recording and consent laws that
apply to you. Sonus Auris is for recording your own environment, not for covertly
recording others.

## Changes

We will update this policy as the app evolves and revise the "Last updated" date.

## Contact

<LEGAL ENTITY NAME>, <postal address>, <privacy@yourdomain>.
