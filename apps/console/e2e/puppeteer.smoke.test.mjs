// End-to-end smoke of the built console web app, driven by Puppeteer (raw CDP)
// under node:test. Run: node --test puppeteer.smoke.test.mjs
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import puppeteer from 'puppeteer';
// Reuse Playwright's bundled Chromium when Puppeteer has no browser of its own
// (the shape used across the cluster's UI smokes and CI images).
import { chromium as playwrightChromium } from 'playwright';

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
let page;
const consoleErrors = [];
const pageErrors = [];
const ignoreHttpsErrors = process.env.CONSOLE_IGNORE_HTTPS_ERRORS === '1';

async function launch() {
  const args = ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'];
  if (ignoreHttpsErrors) args.push('--ignore-certificate-errors');
  try {
    return await puppeteer.launch({ headless: true, args });
  } catch {
    return await puppeteer.launch({
      headless: true,
      executablePath: playwrightChromium.executablePath(),
      args,
    });
  }
}

before(async () => {
  server = await resolveTarget(WEB_DIR);
  browser = await launch();
  page = await browser.newPage();
  page.on('console', (msg) => {
    if (msg.type() === 'error' && isFatalConsole(msg.text())) {
      consoleErrors.push(msg.text());
    }
  });
page.on('pageerror', (err) => pageErrors.push(err.stack ?? String(err)));
  await page.goto(server.url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  await page.evaluate(ENABLE_SEMANTICS_SCRIPT);
});

after(async () => {
  await page?.close().catch(() => {});
  await browser?.close().catch(() => {});
  await server?.close().catch(() => {});
});

test('[puppeteer] the console web build boots Flutter', async () => {
  const hasHost = await page.evaluate(`(${HAS_FLUTTER_HOST})`);
  assert.equal(hasHost, true, 'Flutter render host should be attached');
});

test('[puppeteer] the document title is the console', async () => {
  assert.equal(await page.title(), EXPECTED_TITLE);
});

test('[puppeteer] the passwordless sign-in screen renders', async () => {
  const text = await waitForSemanticText(
    () => page.evaluate(READ_SEMANTICS_TEXT),
    /Sonus Auris/i,
  );
  assert.match(text, /Sign in/i);
  assert.match(text, /Email me a code/i);
  assert.doesNotMatch(text, /magic link|email link|sign-in link/i);
  assert.match(text, /new accounts are created automatically/i);
});

test('[puppeteer] there is no password field (passwordless by design)', async () => {
  // Guard against an actual field labelled "Password" — not the marketing copy
  // ("No password needed"), which legitimately contains the word.
  const labels = (await page.evaluate(READ_SEMANTICS_TEXT))
    .split('\n')
    .map((s) => s.trim().toLowerCase());
  assert.ok(!labels.includes('password'), 'no field should be labelled Password');
  assert.equal(
    await page.$$eval('input[type="password"]', (nodes) => nodes.length),
    0,
    'the rendered app must not contain a password input',
  );
});

test('[puppeteer] passwordless sign-in remains usable at a phone viewport', async () => {
  await page.setViewport({ width: 390, height: 844 });
  const text = await waitForSemanticText(
    () => page.evaluate(READ_SEMANTICS_TEXT),
    /Email me a code/i,
  );
  assert.match(text, /No password needed/i);
  assert.equal(await page.$$eval('input[type="password"]', (nodes) => nodes.length), 0);
  await page.screenshot({ path: join(ARTIFACT_DIR, 'puppeteer-signin-mobile.png') });
});

test(
  '[puppeteer] mobile web renders the real Supabase OTP error',
  { skip: process.env.CONSOLE_TEST_OTP_ERROR !== '1' },
  async () => {
    await page.setRequestInterception(true);
    page.on('request', async (request) => {
      if (request.url().includes('/auth/v1/otp')) {
        if (request.method() === 'OPTIONS') {
          await request.respond({
            status: 204,
            headers: {
              'access-control-allow-origin': '*',
              'access-control-allow-methods': 'POST, OPTIONS',
              'access-control-allow-headers': '*',
            },
          });
          return;
        }
        await request.respond({
          status: 429,
          contentType: 'application/json',
          headers: { 'access-control-allow-origin': '*' },
          body: JSON.stringify({
            code: 429,
            error_code: 'over_email_send_rate_limit',
            msg: 'email rate limit exceeded',
          }),
        });
        return;
      }
      await request.continue();
    });
    const field = await page.$('input[data-semantics-role="text-field"]');
    assert.ok(field, 'Flutter email field should be attached');
    await field.focus();
    const cdp = await page.createCDPSession();
    await cdp.send('Input.insertText', {text: 'browser-error@example.test'});
    await cdp.detach();
    const buttons = await page.$$('flt-semantics[role="button"]');
    let submit;
    for (const button of buttons) {
      const label = await button.evaluate((node) => node.textContent ?? '');
      if (label.includes('Email me a code')) {
        submit = button;
        break;
      }
    }
    assert.ok(submit, 'OTP request button should be attached');
    await submit.click();
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
      path: join(ARTIFACT_DIR, 'puppeteer-real-otp-error-mobile.png'),
    });
  },
);

test('[puppeteer] no fatal console or page errors during boot', async () => {
  assert.deepEqual(pageErrors, [], `page errors: ${pageErrors.join('; ')}`);
  assert.deepEqual(consoleErrors, [], `console errors: ${consoleErrors.join('; ')}`);
});

test('[puppeteer] captures a screenshot artifact', async () => {
  await page.screenshot({ path: join(ARTIFACT_DIR, 'puppeteer-signin.png') });
});
