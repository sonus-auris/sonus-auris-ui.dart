# Google Play — Data safety form answers

Fill the Play Console **Data safety** section from this. Key Play definitions:
"**Collected**" = transmitted off the device. "**Shared**" = transferred to a
third party. Recordings go to storage **you** control and (optionally) through our
backend **client-encrypted**, so we cannot read them — but data that leaves the
device is still declared honestly below.

## Security practices
- **Encrypted in transit:** Yes (TLS/HTTPS).
- **Data protected at rest on device:** Yes. Local rolling files remain in the
  app's private container and rely on device/OS storage protection; recordings
  are additionally sealed with AES-256-GCM before supported cloud transfer.
- **Users can request deletion:** Yes — in-app + web URL (see ACCOUNT_DELETION).
- **Committed to Play Families policy:** app is not directed to children.
- **Independent security review:** optional to declare.

## Data types

| Data type | Collected? | Shared? | Purpose | Optional? |
|---|---|---|---|---|
| **Audio (voice/sound recordings)** | Yes (only if you back up / use backend) | No | App functionality | Optional (off until you record/back up) |
| **Precise location** | Yes (only if geotagging on) | No | App functionality | Optional (off by default) |
| **Approximate location** | Yes (only if geotagging on) | No | App functionality | Optional (off by default) |
| **Email address** | Yes (if creating/signing into an account) | No | Account management, Authentication | Optional |
| **User IDs / Device or other IDs** | Yes (if using the backend account) | No | App functionality, Authentication | Optional |
| **Crash logs / Diagnostics** | Yes (signed-in client telemetry) | No | App functionality, diagnostics | Optional (only after sign-in) |

Notes for the reviewer/console:
- We do **not** select "Data is processed ephemerally" for audio unless true for
  your config; default above assumes optional backup.
- No data is used for **advertising or marketing**, and no data is **sold/shared**
  with third parties. Supabase, connected object stores, and any external
  recognition endpoint the user explicitly configures act as service providers
  or user-directed destinations. No third-party ads/analytics SDKs are bundled.
- Audio sent to your own connected storage (S3/Drive/OneDrive/Dropbox/iCloud) is
  governed by that provider. Supported outbound backups are sealed on-device,
  except iCloud copies are decrypted locally into the user's own iCloud Drive.
  For Play purposes we declare audio as "collected" because it can leave the
  device, and "not shared" because we don't hand it to third parties.
- Optional cloud transcription and song identification can send a bounded audio
  excerpt/fingerprint to the configured recognition provider. Keep Audio declared
  as collected when either feature is present in the shipped build.

> If you ship **without** the optional backend/backup enabled at all, audio,
> location, and IDs may all be "not collected" (everything stays on-device).
> Keep this doc in sync with what the shipped build actually does.
