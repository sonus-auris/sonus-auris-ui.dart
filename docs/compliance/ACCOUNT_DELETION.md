# Account & data deletion

Both stores require this, and they require slightly different things:

- **Apple (App Store Review 5.1.1(v))**: if the app supports account creation, it
  must let users **initiate account deletion from within the app**. A link to a
  web page is not sufficient on its own.
- **Google Play (Data safety)**: provide an **in-app** path **and** a **public web
  URL** where a user can request deletion **without** reinstalling the app, and
  state what is deleted vs. retained (and why).

## Current status / gap to close before submission

⚠️ The backend data model has a soft-deleted state (`status = 'deleted'`), but
there is **no confirmed public "delete my account" endpoint** and the in-app
action may not be wired yet. Before submitting, ensure:

1. **In-app:** Settings → "Delete account" → confirm → calls the backend to delete
   the account and server-side metadata, clears local clips + secure-storage
   tokens/keys, and signs out. (Local-only users with no account: offer "Delete
   all recordings & data".)
2. **Backend:** an authenticated `DELETE /api/mobile/v1/account` (or similar) that
   purges account rows, device tokens, and clip metadata. Backed-up clips live in
   the user's own storage; tell the user those must be removed there (or offer to
   trigger deletion if you hold the credentials).
3. **Web:** host the request page below at a public URL and put it in the Play
   "Data deletion" field and the App Store privacy section.

## What gets deleted vs. retained

| Data | On deletion |
|---|---|
| Account record, auth/device tokens | Deleted |
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
