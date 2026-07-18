// End-to-end smoke of the built console web app, driven by Playwright
// (auto-waiting) under node:test. Run: node --test playwright.smoke.test.mjs
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import { chromium } from 'playwright';

import { resolveTarget } from './lib/static-server.mjs';
import {
  ARTIFACT_DIR,
  ENABLE_SEMANTICS_SCRIPT,
  EXPECTED_TITLE,
  HAS_FLUTTER_HOST,
  READ_SEMANTICS_TEXT,
  WEB_DIR,
  isFatalConsole,
  waitForSemanticText,
} from './lib/flutter-boot.mjs';

let server;
let browser;
let context;
let page;
const consoleErrors = [];
const pageErrors = [];

before(async () => {
  server = await resolveTarget(WEB_DIR);
  browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });
  context = await browser.newContext();
  page = await context.newPage();
  page.on('console', (msg) => {
    if (msg.type() === 'error' && isFatalConsole(msg.text())) {
      consoleErrors.push(msg.text());
    }
  });
  page.on('pageerror', (err) => pageErrors.push(String(err)));
  await page.goto(server.url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  await page.evaluate(ENABLE_SEMANTICS_SCRIPT);
});

after(async () => {
  await context?.close().catch(() => {});
  await browser?.close().catch(() => {});
  await server?.close().catch(() => {});
});

test('[playwright] the console web build boots Flutter', async () => {
  const hasHost = await page.evaluate(HAS_FLUTTER_HOST);
  assert.equal(hasHost, true, 'Flutter render host should be attached');
});

test('[playwright] the document title is the console', async () => {
  assert.equal(await page.title(), EXPECTED_TITLE);
});

test('[playwright] the passwordless sign-in screen renders', async () => {
  const text = await waitForSemanticText(
    () => page.evaluate(READ_SEMANTICS_TEXT),
    /Sonus Auris/i,
  );
  assert.match(text, /Sign in/i);
  assert.match(text, /Email me a code/i);
});

test('[playwright] there is no password field (passwordless by design)', async () => {
  // Guard against an actual field labelled "Password" — not the marketing copy
  // ("No password needed"), which legitimately contains the word.
  const labels = (await page.evaluate(READ_SEMANTICS_TEXT))
    .split('\n')
    .map((s) => s.trim().toLowerCase());
  assert.ok(!labels.includes('password'), 'no field should be labelled Password');
});

test('[playwright] no fatal console or page errors during boot', async () => {
  assert.deepEqual(pageErrors, [], `page errors: ${pageErrors.join('; ')}`);
  assert.deepEqual(consoleErrors, [], `console errors: ${consoleErrors.join('; ')}`);
});

test('[playwright] captures a screenshot artifact', async () => {
  await page.screenshot({ path: join(ARTIFACT_DIR, 'playwright-signin.png') });
});
