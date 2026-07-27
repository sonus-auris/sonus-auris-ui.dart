# Apple App Store — Privacy "Nutrition Label" answers

Complete App Store Connect → App Privacy only after comparing this file with the
production IPA's actual endpoints, build flags, permissions, SDKs, and enabled
features. Apple groups answers into **Used to Track You**, **Linked to You**, and
**Not Linked to You**.

## Tracking

- **Used to track you: NONE.** The app does not track users across apps/websites
  and bundles no advertising SDKs. No App Tracking Transparency prompt is needed
  unless the shipped behavior changes.

## Data linked to the user when the relevant account/off-device feature is used

| Data type (Apple category) | Purpose | Linked? |
|---|---|---|
| **Email Address** | App Functionality, Authentication | Linked when an account is used |
| **User ID / Device ID** | App Functionality, Authentication, Security | Linked |
| **Audio Data** | Recording, encrypted backup/device sync, user-requested sharing or processing | Linked when it leaves the device under an account/device identity |
| **Other User Content** | Transcripts, meeting notes, summaries, tasks, annotations, diction feedback, and user-entered notes | Linked when synced/backed up |
| **Health / Fitness or Other Sensitive Data** | Non-diagnostic sleep/snore or behavioral/acoustic inferences, when Apple's current taxonomy requires this classification | Linked when synced; optional |
| **Coarse Location** | Optional geotagging/context functionality | Linked when enabled and synced |
| **Precise Location** | Optional geotagging | Linked when enabled and synced |
| **Purchase History** | Subscription/entitlement verification and restore | Linked |
| **Crash Data / Other Diagnostic Data** | App operation, diagnostics, security | Linked for signed-in telemetry |
| **Product Interaction** | Consent version, schedule/recording state, transfer status, and feature operation when included in telemetry | Linked for signed-in telemetry |

## Local-only data

The rolling working audio window can remain plaintext inside the app-private
sandbox for **100 hours by default**, or a user-selected shorter period, so
recording, playback, transcription, and approved local analysis can run. Data
that never leaves the device is not "collected" for App Privacy, but the public
privacy policy and in-app disclosure must still explain the local
plaintext/security boundary accurately.

Every ordinary backup or cross-device-sync audio object is encrypted on-device
before leaving. Do not describe the local working window itself as encrypted at
rest while plaintext files exist. Failed or disabled backup must not extend the
local plaintext lifetime beyond the configured 100-hour-or-shorter ceiling.

## Optional external processing

Raw audio is not sent to external AI/transcription services by default. If a
production build enables a user-selected external provider, update App Privacy
for the exact audio, transcript, identifiers, location, derived data, purpose,
linkage, and provider role before release.

## Notes

- For each type select only the purposes used by the shipped app. Do not select
  Advertising or third-party advertising analytics.
- "Product Personalization" may apply to user-requested diction/sleep/meeting
  analysis; decide from Apple's current definitions and document the rationale.
- Keep App Store Connect answers synchronized with
  `ios/Runner/PrivacyInfo.xcprivacy`, the public privacy policy, and the runtime
  data-flow inventory.
- Verify the production build, UI, tests, and retention sweeper all enforce the
  100-hour default and preserve shorter user-selected settings.
- Privacy policy URL: `https://sonusauris.app/privacy/`.
- Account deletion URL: `https://sonusauris.app/account-deletion/`.
- Re-audit whenever providers, SDKs, analysis categories, retention, encryption,
  telemetry, purchases, location, or sync behavior changes.
