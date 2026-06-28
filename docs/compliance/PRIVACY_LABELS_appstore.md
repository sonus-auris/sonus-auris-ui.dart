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
| **Audio Data** | App Functionality | Linked (to account, if you back up / use backend) |
| **Coarse Location** | App Functionality | Linked (only if geotagging enabled) |
| **Precise Location** | App Functionality | Linked (only if geotagging enabled) |
| **User ID / Device ID** | App Functionality, Authentication | Linked |

## Data not linked to the user

| Data type | Purpose | Linked? |
|---|---|---|
| **Crash Data / Performance Data / Diagnostics** | App Functionality | Not linked |

## Notes
- For each type Apple asks the **purposes**: choose **App Functionality** (and
  **Authentication** for IDs). Do **not** select Advertising, Analytics (3rd
  party), or Product Personalization.
- If you ship a build with the backend/backup fully disabled, Audio/Location/IDs
  become "Data Not Collected." Keep this in sync with the shipped build.
- Privacy policy URL is required in App Store Connect (see PRIVACY_POLICY).
- "Data is not used to track you" → leave ATT unimplemented (none required).
