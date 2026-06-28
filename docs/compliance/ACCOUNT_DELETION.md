# Account & data deletion

Both stores require this, and they require slightly different things:

- **Apple (App Store Review 5.1.1(v))**: if the app supports account creation, it
  must let users **initiate account deletion from within the app**. A link to a
  web page is not sufficient on its own.
- **Google Play (Data safety)**: provide an **in-app** path **and** a **public web
  URL** where a user can request deletion **without** reinstalling the app, and
  state what is deleted vs. retained (and why).

## Current status / gap to close before submission

The in-app pathway is wired: Settings / Configure → Account → "Delete account"
confirms with the user, calls the backend, clears local recordings, clears
pending alerts and sleep profile data, and wipes secure-storage secrets.
Before submitting, ensure:

1. **Backend:** deploy `DELETE /api/mobile/v1/account` with
   `SOUND_RECORDER_SUPABASE_SERVICE_ROLE_KEY` set server-side. The endpoint
   verifies the user's Supabase JWT, deletes the Supabase Auth user, revokes
   device/cloud tokens, and marks backend metadata deleted/expired.
2. **In-app:** verify the production build has `SONUS_BACKEND_BASE_URL`,
   `SONUS_SUPABASE_URL`, and `SONUS_SUPABASE_ANON_KEY` so account creation and
   deletion work without developer project fields.
3. **Web:** host the request page below at a public URL and put it in the Play
   "Data deletion" field and the App Store privacy section.

## What gets deleted vs. retained

| Data | On deletion |
|---|---|
| Account record, Supabase Auth user, auth/device tokens | Deleted |
| Clip metadata held by the backend | Deleted |
| On-device recordings, keys, tokens | Wiped from the device |
| Clips you backed up to **your own** storage (S3/Drive/OneDrive/iCloud) | You control these; delete them in that service |
| Minimal transaction logs required by law | Retained only as long as legally required, then deleted |

Target: complete deletion within 30 days of a verified request.

---

## Public deletion-request page (host this)

> Title: **Delete your Sonus Auris account and data**
>
> You can delete your account directly in the app: open **Settings → Delete
> account**. To request deletion without the app, email **<privacy@yourdomain>**
> from the address associated with your account (or the device/account ID shown in
> the app's Settings) with the subject "Delete my account".
>
> We will verify the request and delete your account, authentication tokens, and
> the clip metadata we hold, normally within 30 days. Recordings you backed up to
> your own cloud storage are under your control — delete them in that service.
>
> Questions: **<privacy@yourdomain>**.
