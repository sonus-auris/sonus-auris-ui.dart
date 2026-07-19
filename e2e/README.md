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
field**), and nothing throws during boot. Each run drops a screenshot in
`artifacts/`.

## Run locally

```sh
# from the app root, produce the bundle the smokes serve:
flutter build web --release

cd e2e
npm ci
npx playwright install --with-deps chromium   # one-time browser download
npm test                 # both drivers
npm run test:playwright  # just Playwright
npm run test:puppeteer   # just Puppeteer
```

## CI

`.github/workflows/e2e.yml` builds the web bundle, installs Chromium once, and
runs both suites, uploading `artifacts/` (screenshots) on completion.

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

The suites default to serving local `build/web`; `CONSOLE_BASE_URL` is already
wired through `lib/static-server.mjs` for post-deployment cluster checks.
