# Sonus Auris — Privacy Policy

_Last updated: <SET DATE>. Publisher: <LEGAL ENTITY NAME>, contact: <privacy@yourdomain>._

> This draft is written to match how the app actually behaves. Review the
> bracketed `<…>` placeholders, have counsel review if needed, then host it at a
> stable public URL (e.g. on the Sonus Auris website / GitHub Pages) and enter
> that URL in the App Store and Play Console. Both stores require a reachable
> privacy policy URL.

## Summary

Sonus Auris records audio you choose to capture. Your recordings are **encrypted
on your device** and are **only** sent to cloud storage **you** connect (your own
S3 bucket, Google Drive, OneDrive, or iCloud). We do **not** operate a shared
media server that stores your recordings, and we cannot read your encrypted clips.

## What we collect and why

**Audio recordings** — created only after you tap Start. Stored locally as a
rolling window and encrypted on-device (AES-256-GCM; keys derived with
HKDF/Argon2id and held on your device). Purpose: the core recording feature.

**Optional location** — OFF by default. If you enable geotagging, the approximate
or precise location at capture time is attached to a clip so you can prove where
it was recorded. Purpose: app functionality you opt into.

**Optional on-device audio analysis** — OFF by default. Sleep/snore, music, and
loud-event detection run locally on your device. Detection results stay with your
data; raw audio is not sent anywhere for analysis.

**Account / backend data (only if you use the optional backend)** — a device or
account identifier, authentication tokens, and metadata about clips you choose to
back up or share (timestamps, sizes, upload status). Purpose: authentication,
backup coordination, and optional alert/listening links you request.

**Diagnostics** — limited on-device logs to help the app run. We do not include
third-party advertising or analytics SDKs.

## What we do NOT do

- We do not sell your data.
- We do not use your data for advertising.
- We do not have access to the contents of your encrypted recordings.
- We do not record without you starting capture.

## Where your data goes

- **On your device** by default (encrypted).
- **To storage you control**, if you connect it (your S3-compatible bucket,
  Google Drive, OneDrive, or iCloud). Their handling is governed by their terms.
- **To the optional Sonus Auris backend**, only for features you invoke
  (authentication, backup coordination, alert links). Recordings remain
  client-encrypted; the backend brokers transfers and short-lived links.

## Retention

Local clips age out automatically based on your rolling-window setting. Backed-up
clips persist in your chosen storage until you delete them. Backend metadata is
retained only as long as needed for the feature, and is removed on account
deletion.

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

Recordings are encrypted on-device before storage or upload. Transport uses
TLS/HTTPS. Tokens and keys are stored using platform secure storage (iOS Keychain
/ Android Keystore).

## Recording responsibly

You are responsible for complying with the audio-recording and consent laws that
apply to you. Sonus Auris is for recording your own environment, not for covertly
recording others.

## Changes

We will update this policy as the app evolves and revise the "Last updated" date.

## Contact

<LEGAL ENTITY NAME>, <postal address>, <privacy@yourdomain>.
