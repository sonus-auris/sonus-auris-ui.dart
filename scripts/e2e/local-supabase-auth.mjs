#!/usr/bin/env node

// Runs the real passwordless UI + two-user RLS integration test against the
// sibling repository's local Supabase stack. It requests three independent
// one-time codes and reads them from local Mailpit without printing credentials.

import { execFileSync, spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const uiDir = resolve(scriptDir, '..', '..');
const interfacesDir =
  process.env.SONUS_INTERFACES_DIR ||
  resolve(uiDir, '..', 'sonus-auris-interfaces');
const supabaseArgs = ['--yes', 'supabase@latest'];

function runSupabase(args) {
  return execFileSync('npx', [...supabaseArgs, ...args], {
    cwd: interfacesDir,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function parseStatus(output) {
  const start = output.indexOf('{');
  if (start < 0) {
    throw new Error('Local Supabase did not return JSON status.');
  }
  return JSON.parse(output.slice(start));
}

function localStatus() {
  try {
    return parseStatus(runSupabase(['status', '-o', 'json']));
  } catch {
    process.stdout.write('Starting the local Supabase test stack…\n');
    runSupabase(['start']);
    return parseStatus(runSupabase(['status', '-o', 'json']));
  }
}

async function requestOtp(apiUrl, publishableKey, email) {
  const response = await fetch(`${apiUrl}/auth/v1/otp`, {
    method: 'POST',
    headers: {
      apikey: publishableKey,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ email, create_user: true }),
  });
  if (!response.ok) {
    throw new Error(`Local passwordless request failed (${response.status}).`);
  }
}

async function waitForOtp(mailpitUrl, email) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const response = await fetch(`${mailpitUrl}/api/v1/messages`);
    if (response.ok) {
      const mailbox = await response.json();
      const message = mailbox.messages?.find((candidate) =>
        candidate.To?.some(
          (recipient) => recipient.Address?.toLowerCase() === email,
        ),
      );
      const match = message?.Snippet?.match(/\b\d{6}\b/);
      if (match) {
        return match[0];
      }
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  throw new Error(`Timed out waiting for the local sign-in email for ${email}.`);
}

async function main() {
  const status = localStatus();
  const localApiUrl = status.API_URL;
  const apiUrl = process.env.SONUS_E2E_SUPABASE_URL || localApiUrl;
  const publishableKey = status.PUBLISHABLE_KEY || status.ANON_KEY;
  const mailpitUrl = status.MAILPIT_URL || status.INBUCKET_URL;
  if (!localApiUrl || !apiUrl || !publishableKey || !mailpitUrl) {
    throw new Error('Local Supabase status omitted API, client key, or Mailpit.');
  }
  if (
    process.env.SONUS_E2E_SUPABASE_URL &&
    new URL(apiUrl).protocol !== 'https:'
  ) {
    throw new Error('SONUS_E2E_SUPABASE_URL must use HTTPS.');
  }

  const suffix = `${Date.now()}-${process.pid}`;
  const identities = [
    `sonus-ui-${suffix}@example.test`,
    `sonus-rls-a-${suffix}@example.test`,
    `sonus-rls-b-${suffix}@example.test`,
  ];
  const codes = [];
  for (const email of identities.slice(1)) {
    await requestOtp(apiUrl, publishableKey, email);
    codes.push(await waitForOtp(mailpitUrl, email));
  }

  process.stdout.write(
    'Running the rendered magic-link UI and two-account RLS isolation test…\n',
  );
  const device =
    process.env.SONUS_E2E_DEVICE ||
    (process.platform === 'darwin' ? 'macos' : 'linux');
  const result = spawnSync(
    'flutter',
    [
      'test',
      '-d',
      device,
      'integration_test/live_supabase_auth_test.dart',
      `--dart-define=SONUS_SUPABASE_URL=${apiUrl}`,
      `--dart-define=SONUS_SUPABASE_ANON_KEY=${publishableKey}`,
      `--dart-define=SONUS_TEST_UI_EMAIL=${identities[0]}`,
      `--dart-define=SONUS_TEST_MAILPIT_URL=${mailpitUrl}`,
      `--dart-define=SONUS_TEST_EMAIL=${identities[1]}`,
      `--dart-define=SONUS_TEST_EMAIL_OTP=${codes[0]}`,
      `--dart-define=SONUS_TEST_EMAIL_B=${identities[2]}`,
      `--dart-define=SONUS_TEST_EMAIL_OTP_B=${codes[1]}`,
    ],
    { cwd: uiDir, stdio: 'inherit' },
  );
  if (result.error) {
    throw result.error;
  }
  process.exitCode = result.status ?? 1;
}

main().catch((error) => {
  process.stderr.write(`Local auth E2E failed: ${error.message}\n`);
  process.exitCode = 1;
});
