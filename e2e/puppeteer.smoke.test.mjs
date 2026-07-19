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
  page.on('pageerror', (err) => pageErrors.push(String(err)));
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
});

test('[puppeteer] there is no password field (passwordless by design)', async () => {
  // Guard against an actual field labelled "Password" — not the marketing copy
  // ("No password needed"), which legitimately contains the word.
  const labels = (await page.evaluate(READ_SEMANTICS_TEXT))
    .split('\n')
    .map((s) => s.trim().toLowerCase());
  assert.ok(!labels.includes('password'), 'no field should be labelled Password');
});

test('[puppeteer] no fatal console or page errors during boot', async () => {
  assert.deepEqual(pageErrors, [], `page errors: ${pageErrors.join('; ')}`);
  assert.deepEqual(consoleErrors, [], `console errors: ${consoleErrors.join('; ')}`);
});

test('[puppeteer] captures a screenshot artifact', async () => {
  await page.screenshot({ path: join(ARTIFACT_DIR, 'puppeteer-signin.png') });
});
