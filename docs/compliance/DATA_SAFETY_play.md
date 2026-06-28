# Google Play — Data safety form answers

Fill the Play Console **Data safety** section from this. Key Play definitions:
"**Collected**" = transmitted off the device. "**Shared**" = transferred to a
third party. Recordings go to storage **you** control and (optionally) through our
backend **client-encrypted**, so we cannot read them — but data that leaves the
device is still declared honestly below.

## Security practices
- **Encrypted in transit:** Yes (TLS/HTTPS).
- **Data encrypted at rest on device:** Yes (AES-256-GCM, keys on device).
- **Users can request deletion:** Yes — in-app + web URL (see ACCOUNT_DELETION).
- **Committed to Play Families policy:** app is not directed to children.
- **Independent security review:** optional to declare.

## Data types

| Data type | Collected? | Shared? | Purpose | Optional? |
|---|---|---|---|---|
| **Audio (voice/sound recordings)** | Yes (only if you back up / use backend) | No | App functionality | Optional (off until you record/back up) |
| **Precise location** | Yes (only if geotagging on) | No | App functionality | Optional (off by default) |
| **Approximate location** | Yes (only if geotagging on) | No | App functionality | Optional (off by default) |
| **User IDs / Device IDs** | Yes (if using the backend account) | No | App functionality, Authentication | Optional |
| **App activity / diagnostics (crash, performance)** | Yes (minimal, on-device logs) | No | App functionality, diagnostics | — |

Notes for the reviewer/console:
- We do **not** select "Data is processed ephemerally" for audio unless true for
  your config; default above assumes optional backup.
- No data is used for **advertising or marketing**, and no data is **sold/shared**
  with third parties. No third-party ads/analytics SDKs are bundled.
- Audio sent to your own connected storage (S3/Drive/OneDrive/iCloud) is governed
  by that provider; for Play purposes we declare audio as "collected" because it
  can leave the device, and "not shared" because we don't hand it to third parties.

> If you ship **without** the optional backend/backup enabled at all, audio,
> location, and IDs may all be "not collected" (everything stays on-device).
> Keep this doc in sync with what the shipped build actually does.
