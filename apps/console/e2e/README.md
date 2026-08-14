# Console E2E smokes (Puppeteer + Playwright)

End-to-end browser smokes for the built console web app. The **same assertions**
run under **both** drivers via `node:test`:

- **Playwright** — first-class auto-waiting; the happy-path default.
- **Puppeteer** — closer to raw CDP; catches headless-Chrome issues auto-waiting
  can mask. Falls back to Playwright's bundled Chromium when it has no browser
  of its own (matches the cluster's UI-smoke images).

Both suites: serve `../build/web` on an ephemeral port, boot Flutter, enable the
accessibility (semantics) tree — Flutter web paints to canvas, so text only
becomes queryable once semantics are on — then assert the app boots, the title
is correct, the **passwordless** sign-in screen renders (with **no password
field** at both desktop and phone viewports), confirm the OTP-only/new-account
copy contains no link fallback, and verify nothing throws during boot. Each run
drops desktop and mobile screenshots in `artifacts/`.

## Auth guarantees (`playwright.auth.test.mjs`)

A second Playwright suite drives the **auth surface** rather than just boot. It
opens a fresh browser context per case — its own storage, its own start URL —
and pins the invariants that exist only on the client:

| Assertion | Guards |
| --- | --- |
| Typing an email and submitting persists a PKCE verifier but **no token** | `token_store.dart` keeps web sessions in memory; browser storage is script-readable |
| Legacy session keys planted in `localStorage` are purged at boot | the same in-memory guarantee, from the other direction |
| No `localStorage` / `sessionStorage` / IndexedDB entry ever looks like a session | ditto |
| A `?code=…` callback the browser never requested is refused, and the code is scrubbed from the URL | PKCE pending-link binding in `console_controller.dart` |
| A `#access_token=…&refresh_token=…` callback is refused, never adopted | implicit-flow session fixation |
| A pending link older than 15 minutes is rejected **and cleared**, while an otherwise identical 1-minute-old one reaches the exchange | the expiry window itself — the pair isolates it from the redirect binding |
| Unreadable pending state is dropped rather than surfaced as an internal error | hostile/corrupt browser storage |
| An `?error_description=…` callback is reported without echoing its text | reflecting attacker-controlled text |

This suite is hermetic: the bundle is built **without** `SONUS_SUPABASE_*`
defines, so every flow runs client-side and stops at the key-policy guard —
which is downstream of all the decisions under test. No Supabase project, no
network, nothing to skip.

```sh
npm run test:auth
```

## Run locally

```sh
# from the app root, produce the bundle the smokes serve:
flutter build web --release

cd e2e
npm ci
npx playwright install --with-deps chromium   # one-time browser download
npm test                 # every suite
npm run test:playwright  # just the Playwright boot smoke
npm run test:puppeteer   # just the Puppeteer boot smoke
npm run test:auth        # just the auth guarantees
```

## CI

`.github/workflows/e2e.yml` builds the web bundle, installs Chromium once, then
runs the boot smokes and the auth guarantees as separate steps (the auth step
runs even if the smokes fail, so one report covers both), uploading
`artifacts/` (screenshots) on completion. `.github/workflows/ci.yml` runs the
same suites via `npm test` alongside `flutter analyze` / `flutter test`.

## Running on the cluster's browser runners

`~/codes/ores/k8s-cluster` already hosts browser automation infra that backs all
drivers with one bundled Chromium:

- `remote/deployments/browser-test-server` — a Fastify service driving
  Playwright + Puppeteer + Selenium behind one scenario API (Playwright Noble
  base image; `playwright.chromium.executablePath()` backs every driver).
- `remote/tests` — the cluster's `ui-playwright-smoke.mjs` / `ui-puppeteer-smoke.mjs`
  suite (`pnpm test:ui:playwright`, `test:ui:puppeteer`).

To run these console smokes on that infra, point them at a deployed console URL
instead of the local static server by setting `CONSOLE_BASE_URL`, and reuse the
runner image's Chromium (no per-job browser download):

```sh
CONSOLE_BASE_URL=https://console.sonusauris.app \
  PLAYWRIGHT_CHROMIUM=1 node --test playwright.smoke.test.mjs
```

For a local port-forward or an ephemeral environment with a deliberately
untrusted certificate, opt in explicitly instead of weakening the default:

```sh
CONSOLE_BASE_URL=https://127.0.0.1:18443/sonus-console \
  CONSOLE_IGNORE_HTTPS_ERRORS=1 npm test
```

The suites default to serving local `build/web`; `CONSOLE_BASE_URL` is already
wired through `lib/static-server.mjs` for post-deployment cluster checks.
