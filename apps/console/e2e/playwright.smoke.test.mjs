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
const ignoreHttpsErrors = process.env.CONSOLE_IGNORE_HTTPS_ERRORS === '1';

before(async () => {
  server = await resolveTarget(WEB_DIR);
  browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });
  context = await browser.newContext({ ignoreHTTPSErrors: ignoreHttpsErrors });
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
  assert.doesNotMatch(text, /magic link|email link|sign-in link/i);
  assert.match(text, /new accounts are created automatically/i);
});

test('[playwright] there is no password field (passwordless by design)', async () => {
  // Guard against an actual field labelled "Password" — not the marketing copy
  // ("No password needed"), which legitimately contains the word.
  const labels = (await page.evaluate(READ_SEMANTICS_TEXT))
    .split('\n')
    .map((s) => s.trim().toLowerCase());
  assert.ok(!labels.includes('password'), 'no field should be labelled Password');
  assert.equal(
    await page.locator('input[type="password"]').count(),
    0,
    'the rendered app must not contain a password input',
  );
});

test('[playwright] passwordless sign-in remains usable at a phone viewport', async () => {
  await page.setViewportSize({ width: 390, height: 844 });
  const text = await waitForSemanticText(
    () => page.evaluate(READ_SEMANTICS_TEXT),
    /Email me a code/i,
  );
  assert.match(text, /No password needed/i);
  assert.equal(await page.locator('input[type="password"]').count(), 0);
  await page.screenshot({ path: join(ARTIFACT_DIR, 'playwright-signin-mobile.png') });
});

test(
  '[playwright] mobile web renders the real Supabase OTP error',
  { skip: process.env.CONSOLE_TEST_OTP_ERROR !== '1' },
  async () => {
    await page.route('**/auth/v1/otp**', async (route) => {
      await route.fulfill({
        status: 429,
        contentType: 'application/json',
        headers: { 'access-control-allow-origin': '*' },
        body: JSON.stringify({
          code: 429,
          error_code: 'over_email_send_rate_limit',
          msg: 'email rate limit exceeded',
        }),
      });
    });
    const field = page.locator('input[data-semantics-role="text-field"]').first();
    await field.fill('browser-error@example.test');
    await page
      .locator('flt-semantics[role="button"]', { hasText: 'Email me a code' })
      .first()
      .click({ force: true });
    const text = await waitForSemanticText(
      () => page.evaluate(READ_SEMANTICS_TEXT),
      /email rate limit exceeded/i,
    );
    assert.doesNotMatch(text, /Sending the sign-in code failed/i);
    for (let index = consoleErrors.length - 1; index >= 0; index -= 1) {
      if (/status of 429 \(Too Many Requests\)/i.test(consoleErrors[index])) {
        consoleErrors.splice(index, 1);
      }
    }
    await page.screenshot({
      path: join(ARTIFACT_DIR, 'playwright-real-otp-error-mobile.png'),
    });
  },
);

test('[playwright] no fatal console or page errors during boot', async () => {
  assert.deepEqual(pageErrors, [], `page errors: ${pageErrors.join('; ')}`);
  assert.deepEqual(consoleErrors, [], `console errors: ${consoleErrors.join('; ')}`);
});

test('[playwright] captures a screenshot artifact', async () => {
  await page.screenshot({ path: join(ARTIFACT_DIR, 'playwright-signin.png') });
});
