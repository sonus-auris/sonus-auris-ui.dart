# Apple App Store — Privacy "Nutrition Label" answers

Fill App Store Connect → App Privacy from this. Apple groups answers into three
buckets: **Used to Track You**, **Linked to You**, **Not Linked to You**.

## Tracking
- **Used to track you: NONE.** The app does not track users across apps/websites
  and bundles no advertising/3rd-party-analytics SDKs. (No App Tracking
  Transparency prompt needed.)

## Data linked to the user (only when the optional account/backend is used)

| Data type (Apple category) | Purpose | Linked? |
|---|---|---|
| **Email Address** | App Functionality | Linked (only if account used) |
| **Audio Data** | App Functionality | Linked (to account, if you back up / use backend) |
| **Coarse Location** | App Functionality | Linked (only if geotagging enabled) |
| **Precise Location** | App Functionality | Linked (only if geotagging enabled) |
| **User ID / Device ID** | App Functionality, Authentication | Linked |
| **Crash Data / Other Diagnostic Data** | App Functionality | Linked (signed-in telemetry is scoped by user/device ID) |

## Notes
- For each type Apple asks the **purposes**: choose **App Functionality** (and
  **Authentication** for IDs). Do **not** select Advertising, Analytics (3rd
  party), or Product Personalization.
- Keep App Store Connect answers synchronized with `ios/Runner/PrivacyInfo.xcprivacy`.
- If you ship a build with the backend/backup fully disabled, Audio/Location/IDs
  become "Data Not Collected." Keep this in sync with the shipped build.
- Privacy policy URL: `https://sonusauris.app/privacy/`.
- "Data is not used to track you" → leave ATT unimplemented (none required).
