// Browser assertions for the console's passwordless auth invariants.
//
// The smoke suite proves the app boots; this suite drives the *auth* surface in
// real headless Chrome against the real `flutter build web --release` bundle
// and pins the guarantees that only exist client-side:
//
//   1. web sessions live in memory only — no bearer token ever reaches
//      localStorage / sessionStorage / IndexedDB (`token_store.dart`);
//   2. a magic-link callback the browser never asked for is refused;
//   3. implicit-flow callbacks (a session handed over in the URL) are refused;
//   4. the pending-link expiry window is enforced before any code exchange;
//   5. none of the above throws, and none of it echoes attacker-controlled text.
//
// Everything here is hermetic: no Supabase, no network. The bundle is built
// without `SONUS_SUPABASE_*` defines, so the flow runs entirely client-side and
// stops at the key-policy guard — which is exactly where the auth decisions
// under test are made. Run: node --test playwright.auth.test.mjs
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { after, before, describe, test } from 'node:test';

import { chromium } from 'playwright';

import { resolveTarget } from './lib/static-server.mjs';
import { ARTIFACT_DIR, WEB_DIR } from './lib/flutter-boot.mjs';
import {
  BOOT_TIMEOUT_MS,
  DEVICE_ID_SUFFIX,
  FORBIDDEN_SESSION_SUFFIXES,
  PENDING_AUTH_SUFFIX,
  keysEndingWith,
  openConsole,
  pendingMagicLink,
  readPendingRecord,
  storageBlob,
} from './lib/console-page.mjs';

// `shared_preferences` namespaces the keys it writes; seeds must use the same
// key the plugin will read. Every seeded case also asserts the app *reacted* to
// the seed, so a prefix change surfaces as a failure rather than a silent skip.
const SEEDED_PENDING_KEY = `flutter.${PENDING_AUTH_SUFFIX}`;

let server;
let browser;

before(async () => {
  server = await resolveTarget(WEB_DIR);
  browser = await chromium.launch({
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
    ],
  });
});

after(async () => {
  await browser?.close().catch(() => {});
  await server?.close().catch(() => {});
});

/// Fails if any browser-persisted key looks like a session credential, or if
/// any of [secrets] turns up anywhere in browser storage.
function assertNoPersistedSession(storage, secrets = []) {
  for (const suffix of FORBIDDEN_SESSION_SUFFIXES) {
    assert.deepEqual(
      keysEndingWith(storage, suffix),
      [],
      `web builds must not persist ${suffix}`,
    );
  }
  const blob = storageBlob(storage);
  for (const secret of secrets) {
    assert.ok(
      !blob.includes(secret.toLowerCase()),
      `"${secret}" must never be written to browser storage`,
    );
  }
  assert.ok(
    !/access_?token|refresh_?token/.test(blob),
    `no token-shaped material may be stored; saw: ${blob.slice(0, 400)}`,
  );
  assert.deepEqual(
    storage.databases,
    [],
    `the console must not open an IndexedDB session store; saw ${storage.databases}`,
  );
}

/// Asserts the app is still sitting on the signed-out sign-in surface.
function assertStillSignedOut(text) {
  assert.match(text, /Email me a code/i, 'sign-in surface should still render');
  assert.match(text, /Sign in/i);
  assert.doesNotMatch(
    text,
    /Two-factor authentication|Protect your account|Check your email/i,
    'a rejected callback must not advance the sign-in journey',
  );
}

describe('boot + passwordless happy path', () => {
  test('boots clean and renders the code-first sign-in step', async () => {
    const app = await openConsole(browser, server.url);
    try {
      const text = await app.waitForText(/Email me a code/i);
      assert.match(text, /6-digit one-time code/i);
      assert.match(text, /No password needed/i);
      assert.match(text, /new accounts are created automatically/i);
      assert.equal(
        await app.page.locator('input[type="password"]').count(),
        0,
        'the passwordless console must render no password input',
      );

      // A plain page load is delivered on the same channel as a real callback;
      // it must not be reported to the visitor as a broken sign-in link.
      assert.doesNotMatch(text, /sign-in link/i);
      assert.doesNotMatch(text, /magic link was not requested/i);

      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('requesting a code stores PKCE state and never a session', async () => {
    const app = await openConsole(browser, server.url);
    try {
      await app.waitForText(/Email me a code/i);

      const submit = app.button('Email me a code');
      assert.equal(
        await submit.getAttribute('aria-disabled'),
        'true',
        'the submit button starts disabled with no email',
      );

      await app.fillEmail('browser-test@example.test');
      // Flutter only enables the button once it has actually received the
      // text, so this doubles as proof the typing landed in the app.
      await app.page.waitForFunction(
        () =>
          !Array.from(document.querySelectorAll('flt-semantics[role="button"]'))
            .filter((n) => n.textContent.includes('Email me a code'))
            .some((n) => n.getAttribute('aria-disabled') === 'true'),
        null,
        { timeout: BOOT_TIMEOUT_MS },
      );

      await submit.click({ force: true });

      // Without Supabase configured the request stops at the client key policy
      // — after the PKCE state has been generated and persisted.
      await app.waitForText(/Supabase anon key is required/i);

      const storage = await app.storage();
      const pending = readPendingRecord(storage);
      assert.ok(
        pending,
        'the PKCE verifier must be persisted so the emailed link can be redeemed',
      );
      assert.match(
        pending.code_verifier,
        /^[A-Za-z0-9._~-]{43,128}$/,
        'a valid RFC 7636 verifier should have been stored',
      );
      assert.equal(pending.email, 'browser-test@example.test');
      assert.ok(!('access_token' in pending));
      assert.ok(!('refresh_token' in pending));

      // The store did write to localStorage, so the absence of a session below
      // is a real guarantee rather than an empty-storage coincidence.
      assertNoPersistedSession(storage);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);

      await app.page.screenshot({
        path: join(ARTIFACT_DIR, 'playwright-auth-code-requested.png'),
      });
    } finally {
      await app.close();
    }
  });
});

describe('magic-link callbacks are validated in the browser', () => {
  test('an unsolicited callback is refused', async () => {
    const app = await openConsole(browser, server.url, {
      path: '/?code=forged-authorization-code',
    });
    try {
      const text = await app.waitForText(/was not requested in this browser/i);
      assertStillSignedOut(text);
      assertNoPersistedSession(await app.storage(), [
        'forged-authorization-code',
      ]);

      // The one-time code must not be left in the address bar or in history.
      const storage = await app.storage();
      assert.equal(storage.search, '', 'the callback code should be scrubbed');
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('an implicit-flow callback is refused, not adopted', async () => {
    // A complete, well-formed, unexpired aal2 JWT handed over in the URL. If
    // the implicit flow were still honoured this would sign the visitor in.
    const claims = Buffer.from(
      JSON.stringify({
        sub: 'attacker-user',
        email: 'victim@example.test',
        aal: 'aal2',
        amr: [{ method: 'magiclink' }, { method: 'totp' }],
        exp: Math.floor(Date.now() / 1000) + 3600,
      }),
    ).toString('base64url');
    const forgedAccess = `eyJhbGciOiJIUzI1NiJ9.${claims}.sig`;
    const forgedRefresh = 'forged-refresh-token-value';

    const app = await openConsole(browser, server.url, {
      path: `/#access_token=${forgedAccess}&refresh_token=${forgedRefresh}&expires_in=3600`,
    });
    try {
      const text = await app.waitForText(/older sign-in link is not accepted/i);
      assertStillSignedOut(text);
      assertNoPersistedSession(await app.storage(), [
        forgedAccess,
        forgedRefresh,
        'attacker-user',
      ]);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('a callback error is reported without echoing its text', async () => {
    const injected = 'INJECTED-PROVIDER-TEXT';
    const app = await openConsole(browser, server.url, {
      path: `/?error=access_denied&error_code=403&error_description=${injected}`,
    });
    try {
      const text = await app.waitForText(/invalid or expired/i);
      assertStillSignedOut(text);
      assert.ok(
        !text.includes(injected),
        'attacker-controlled callback text must not be rendered back',
      );
      assertNoPersistedSession(await app.storage());
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('a callback with two codes is refused', async () => {
    const app = await openConsole(browser, server.url, {
      path: '/?code=first-code&code=second-code',
    });
    try {
      const text = await app.waitForText(/did not contain one authorization/i);
      assertStillSignedOut(text);
      assertNoPersistedSession(await app.storage(), [
        'first-code',
        'second-code',
      ]);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });
});

describe('pending magic-link expiry is enforced', () => {
  // These two cases differ ONLY in the age of the stored pending record, so the
  // different outcomes isolate the expiry check itself. Without the control
  // below, the rejection could just as easily come from a bad redirect binding.

  test('a pending link older than the window is rejected and cleared', async () => {
    const app = await openConsole(browser, server.url, {
      path: '/?code=forged-authorization-code',
      seedLocalStorage: {
        [SEEDED_PENDING_KEY]: pendingMagicLink({ minutesAgo: 16 }),
      },
    });
    try {
      const text = await app.waitForText(/sign-in request expired/i);
      assertStillSignedOut(text);

      const storage = await app.storage();
      assert.deepEqual(
        keysEndingWith(storage, PENDING_AUTH_SUFFIX),
        [],
        'an expired pending record must be cleared, not left to be replayed',
      );
      assertNoPersistedSession(storage, ['forged-authorization-code']);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('a pending link inside the window reaches the code exchange', async () => {
    const app = await openConsole(browser, server.url, {
      path: '/?code=forged-authorization-code',
      seedLocalStorage: {
        [SEEDED_PENDING_KEY]: pendingMagicLink({ minutesAgo: 1 }),
      },
    });
    try {
      // Control: identical seed, one minute old. It clears every binding check
      // and stops only at the (unconfigured) Supabase key policy, proving the
      // sibling test above was rejected by the age check and nothing else.
      const text = await app.waitForText(/Supabase anon key is required/i);
      assert.doesNotMatch(text, /sign-in request expired/i);
      assertStillSignedOut(text);

      const storage = await app.storage();
      assert.notDeepEqual(
        keysEndingWith(storage, PENDING_AUTH_SUFFIX),
        [],
        'a live pending record survives a failed exchange so it can be retried',
      );
      assertNoPersistedSession(storage, ['forged-authorization-code']);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('unreadable pending state is dropped, not surfaced', async () => {
    // Browser storage is writable by any injected script. A value of the wrong
    // shape must not escape as an internal error, and must self-heal.
    const app = await openConsole(browser, server.url, {
      path: '/?code=forged-authorization-code',
      seedLocalStorage: { [SEEDED_PENDING_KEY]: '{"not":"a prefs string"}' },
    });
    try {
      const text = await app.waitForText(/was not requested in this browser/i);
      assertStillSignedOut(text);
      assert.doesNotMatch(
        text,
        /TypeError|Instance of|minified:/i,
        'internal error text must not reach the user',
      );

      const storage = await app.storage();
      assert.deepEqual(
        keysEndingWith(storage, PENDING_AUTH_SUFFIX),
        [],
        'the unreadable record should have been dropped',
      );
      assertNoPersistedSession(storage);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });
});

describe('browser storage carries no credentials', () => {
  test('a session left in browser storage is purged at boot', async () => {
    // `PrefsTokenStore` keeps web sessions in memory and actively purges any
    // session written by an older build. Planting those keys and watching them
    // disappear pins that behaviour: a store that persisted sessions again
    // would have to drop this purge to avoid deleting its own writes.
    const stale = {
      [`flutter.${FORBIDDEN_SESSION_SUFFIXES[0]}`]: JSON.stringify(
        'stale.access.token',
      ),
      [`flutter.${FORBIDDEN_SESSION_SUFFIXES[1]}`]: JSON.stringify(
        'stale-refresh-token',
      ),
      [`flutter.${FORBIDDEN_SESSION_SUFFIXES[2]}`]: JSON.stringify(
        '2099-01-01T00:00:00Z',
      ),
      [`flutter.${FORBIDDEN_SESSION_SUFFIXES[3]}`]: JSON.stringify('user-1'),
      [`flutter.${FORBIDDEN_SESSION_SUFFIXES[4]}`]:
        JSON.stringify('stale@example.test'),
    };
    const app = await openConsole(browser, server.url, {
      seedLocalStorage: stale,
    });
    try {
      const text = await app.waitForText(/Email me a code/i);

      // The stale session must neither survive nor sign anybody in.
      assertStillSignedOut(text);
      assertNoPersistedSession(await app.storage(), [
        'stale.access.token',
        'stale-refresh-token',
        'stale@example.test',
      ]);
      assert.deepEqual(app.pageErrors, []);
      assert.deepEqual(app.consoleErrors, []);
    } finally {
      await app.close();
    }
  });

  test('only the non-secret install id and PKCE state may persist', async () => {
    const app = await openConsole(browser, server.url);
    try {
      await app.waitForText(/Email me a code/i);
      const storage = await app.storage();
      const allowed = [PENDING_AUTH_SUFFIX, DEVICE_ID_SUFFIX];
      const unexpected = [
        ...Object.keys(storage.local),
        ...Object.keys(storage.session),
      ].filter((key) => !allowed.some((suffix) => key.endsWith(suffix)));

      assert.deepEqual(
        unexpected,
        [],
        `unexpected browser-persisted keys: ${unexpected.join(', ')}`,
      );
      assertNoPersistedSession(storage);
    } finally {
      await app.close();
    }
  });
});
