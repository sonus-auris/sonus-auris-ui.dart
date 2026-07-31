# Google Play — Data safety form answers

Fill the Play Console **Data safety** section from this file only after comparing
it with the production AAB's actual build flags, permissions, endpoints, and
runtime behavior. In Play's terminology, data that is transmitted off-device is
"collected" even when it is encrypted and the service cannot read it. Whether a
processor or user-directed destination is "shared" must be answered from the
current Play definitions and the exact shipped integration.

## Security practices

- **Encrypted in transit:** Yes (TLS/HTTPS).
- **Encrypted before backup/device sync:** Yes. Each outbound audio object uses
  authenticated on-device envelope encryption (AES-256-GCM); the server/object
  store receives ciphertext and wrapped object keys.
- **All data encrypted at rest on the device:** Do **not** claim this while the
  rolling working window remains plaintext in app-private storage. The intended
  default and maximum supported local plaintext window is **100 hours**, with
  user-selected shorter values. App backup is disabled for that cache, and
  expired plaintext/temp/derived files must be deleted deterministically even
  when backup is disabled or failing.
- **Users can request deletion:** Yes — in-app plus the public account-deletion
  URL (see ACCOUNT_DELETION).
- **Committed to Play Families policy:** app is not directed to children.
- **Independent security review:** declare only after a qualifying review exists.

## Data types

| Data type | Collected? | Shared? | Purpose | Optional? |
|---|---|---|---|---|
| **Audio / voice or sound recordings** | Yes when encrypted backup/sync, alerts, sharing, or explicitly enabled external processing sends data off-device | Re-evaluate for each connected storage/processing provider under current Play definitions | App functionality | Recording is core; each off-device path is separately controlled |
| **Transcripts, notes, summaries, tasks, and other user content** | Yes only if account sync, backup, sharing, or external processing is enabled for those records | Re-evaluate per provider | App functionality, product personalization requested by the user | Optional; analysis categories default to their documented settings |
| **Health/fitness-like or behavioral inferences** | Yes only if sleep/acoustic/diction-derived records sync off-device | No by default; re-evaluate if an external processor receives them | App functionality | Optional and non-diagnostic |
| **Precise location** | Yes only if geotagging is enabled and the resulting record leaves the device | Re-evaluate per destination | App functionality | Optional, off by default |
| **Approximate location** | Yes only if geotagging is enabled and the resulting record leaves the device | Re-evaluate per destination | App functionality | Optional, off by default |
| **Email address** | Yes when creating/signing into an account | No by default | Account management, authentication | Optional account |
| **User IDs / device or other IDs** | Yes when using account, backend, encrypted sync, billing, or diagnostics | No by default | App functionality, authentication, fraud/security | Optional account-dependent paths |
| **Crash logs / diagnostics** | Yes for signed-in client telemetry | No by default | App functionality, diagnostics, security | Optional/account-dependent |
| **App interactions / feature state** | Yes if telemetry includes operation state, consent version, schedule state, or transfer status | No by default | App functionality, diagnostics | Optional/account-dependent |
| **Purchase history** | Yes when store purchases/entitlements are verified | Apple/Google and the verification service participate in the transaction | App functionality, account management | Optional purchase |

## Required reviewer notes

- Recording begins only after the user taps Start, accepts a recording prompt, or
  explicitly arms a schedule.
- A schedule records user intent but cannot override force-stop, force-quit,
  permission, or killed-process restrictions.
- Android shows a persistent notification while the foreground service is active;
  iOS shows its system microphone indicator during capture.
- Exact alarms persist/reconcile schedule state and do not directly open the
  microphone from a prohibited background receiver.
- Local plaintext is limited to the app-private rolling window for 100 hours by
  default or a shorter selected period; every ordinary backup/device-sync audio
  object is encrypted before leaving the device.
- Failed or disabled backup does not authorize plaintext retention beyond the
  configured ceiling.
- Raw audio is not sent to an external AI/transcription provider by default. Any
  optional provider must be separately enabled and disclosed.
- No data is sold or used for advertising or cross-app tracking.

## Release checklist

- [ ] Compare this document against the production merged manifest, native
      capabilities, privacy manifest, Dart dependencies, build flags, and URLs.
- [ ] Verify the 100-hour default in constructor/deserialization, UI, tests,
      retention sweeper, README, policy, and production binary.
- [ ] Prove expired pending/failed/unconfigured uploads and every sensitive
      companion artifact are removed at the 100-hour-or-shorter ceiling.
- [ ] Decide the current Play "shared" answer for every user-directed storage and
      external-processing provider; retain the rationale and contract role.
- [ ] Confirm account deletion removes ciphertext, metadata, device keys/public
      records, transcripts, summaries, diagnostics, and local files as promised.
- [ ] Upload the foreground-service/exact-alarm demonstration video and reviewer
      instructions from a production-signed build.
- [ ] Re-run the form audit whenever permissions, SDKs, providers, analysis
      categories, retention, or sync behavior changes.
