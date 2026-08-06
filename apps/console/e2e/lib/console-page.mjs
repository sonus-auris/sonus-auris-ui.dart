// Opens the built console in a fresh, isolated browser context.
//
// Every auth assertion needs its own storage state and its own start URL, so
// each case gets a brand-new context rather than sharing the smoke suite's
// single page. Console/page errors are collected per context so a test can
// assert the app stayed quiet while rejecting a hostile callback.
import {
  ENABLE_SEMANTICS_SCRIPT,
  READ_SEMANTICS_TEXT,
  isFatalConsole,
  waitForSemanticText,
} from './flutter-boot.mjs';

/// The `shared_preferences` web backend namespaces every key it writes (today
/// with a `flutter.` prefix). Match on the suffix so assertions do not depend
/// on that prefix staying put.
export const PENDING_AUTH_SUFFIX = 'sonus.console.pendingAuth.v1';
export const DEVICE_ID_SUFFIX = 'sonus.console.deviceId';

/// How long to wait for the app to paint a given piece of text. Sized for a
/// cold CanvasKit boot on a contended CI runner, not the warm local case.
export const BOOT_TIMEOUT_MS = 90_000;

/// `shared_preferences` stores each value JSON-encoded, so a Dart `String`
/// lands in `localStorage` as a JSON *string literal* — double-encoded once
/// the payload is itself JSON. Seeds have to match or the plugin throws.
export function encodePrefsString(value) {
  return JSON.stringify(value);
}

/// Builds the `PendingMagicLink` record `token_store.dart` persists, aged by
/// [minutesAgo]. `__REDIRECT_URL__` is substituted in-page by [openConsole].
export function pendingMagicLink({
  minutesAgo = 0,
  email = 'seeded@example.test',
  supabaseUrl = '',
  redirectUrl = '__REDIRECT_URL__',
  // A syntactically valid RFC 7636 verifier, so rejection can never be blamed
  // on the verifier itself.
  codeVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
} = {}) {
  return encodePrefsString(
    JSON.stringify({
      code_verifier: codeVerifier,
      email,
      supabase_url: supabaseUrl,
      redirect_url: redirectUrl,
      requested_at: new Date(Date.now() - minutesAgo * 60_000).toISOString(),
    }),
  );
}

/// Key suffixes that must NEVER appear in browser storage: `token_store.dart`
/// deliberately keeps web sessions in memory only, because a Supabase refresh
/// token is a long-lived bearer credential and `localStorage`/IndexedDB are
/// readable by any injected script.
export const FORBIDDEN_SESSION_SUFFIXES = [
  'sonus.console.accessToken',
  'sonus.console.refreshToken',
  'sonus.console.expiresAt',
  'sonus.console.userId',
  'sonus.console.email',
];

/// Reads every key/value pair in localStorage and sessionStorage, plus the
/// names of any IndexedDB databases, as one snapshot.
export const READ_BROWSER_STORAGE = `
  (async () => {
    const dump = (store) => {
      const out = {};
      for (let i = 0; i < store.length; i++) {
        const key = store.key(i);
        out[key] = store.getItem(key);
      }
      return out;
    };
    let databases = [];
    try {
      if (indexedDB.databases) {
        databases = (await indexedDB.databases()).map((d) => d.name ?? '');
      }
    } catch (_) {
      databases = [];
    }
    return {
      local: dump(window.localStorage),
      session: dump(window.sessionStorage),
      databases,
      search: window.location.search,
      hash: window.location.hash,
    };
  })()
`;

/// Opens `${baseUrl}${path}` in a fresh context.
///
/// `seedLocalStorage` is written before any app script runs, which is how a
/// test can plant a pending PKCE record (e.g. an expired one) and observe how
/// the real callback handler treats it.
export async function openConsole(
  browser,
  baseUrl,
  { path = '/', seedLocalStorage = null } = {},
) {
  const context = await browser.newContext({
    ignoreHTTPSErrors: process.env.CONSOLE_IGNORE_HTTPS_ERRORS === '1',
  });
  const consoleErrors = [];
  const pageErrors = [];
  const page = await context.newPage();
  page.on('console', (msg) => {
    if (msg.type() === 'error' && isFatalConsole(msg.text())) {
      consoleErrors.push(msg.text());
    }
  });
  page.on('pageerror', (err) => pageErrors.push(String(err)));

  if (seedLocalStorage) {
    // Runs before any app script. `__REDIRECT_URL__` is resolved in-page so a
    // seeded record can carry the exact callback URL the app derives from
    // `Uri.base` (origin + path, no query/fragment) whatever port we bound to.
    await page.addInitScript((entries) => {
      const redirect = window.location.origin + window.location.pathname;
      for (const [key, value] of Object.entries(entries)) {
        window.localStorage.setItem(
          key,
          value.split('__REDIRECT_URL__').join(redirect),
        );
      }
    }, seedLocalStorage);
  }

  await page.goto(`${baseUrl}${path}`, {
    waitUntil: 'domcontentloaded',
    timeout: 60_000,
  });
  await page.evaluate(ENABLE_SEMANTICS_SCRIPT);

  return {
    page,
    consoleErrors,
    pageErrors,
    /// All aria-labelled text currently in the semantics tree.
    text: () => page.evaluate(READ_SEMANTICS_TEXT),
    /// Polls the semantics tree until [pattern] shows up. The default budget is
    /// generous because a cold CanvasKit boot on a loaded CI runner has been
    /// seen to take ~20s, an order of magnitude over the warm case.
    waitForText: (pattern, timeoutMs = BOOT_TIMEOUT_MS) =>
      waitForSemanticText(
        () => page.evaluate(READ_SEMANTICS_TEXT),
        pattern,
        timeoutMs,
      ),
    storage: () => page.evaluate(READ_BROWSER_STORAGE),
    close: () => context.close().catch(() => {}),

    /// Flutter web paints to canvas; with semantics on it exposes the focused
    /// text field as a real `<input>` and each button as a labelled node.
    /// Typing here goes through Flutter's own input handling, so the app only
    /// reacts if it genuinely received the text.
    fillEmail: async (value) => {
      const field = page
        .locator('input[data-semantics-role="text-field"]')
        .first();
      await field.waitFor({ state: 'attached', timeout: BOOT_TIMEOUT_MS });
      await field.fill(value);
    },
    button: (label) =>
      page.locator('flt-semantics[role="button"]', { hasText: label }).first(),
  };
}

/// Reads the `PendingMagicLink` record the app persisted, or null. The value is
/// JSON-encoded by `shared_preferences` and is itself JSON.
export function readPendingRecord(storage) {
  const key = keysEndingWith(storage, PENDING_AUTH_SUFFIX)[0];
  if (!key) return null;
  const raw = storage.local[key] ?? storage.session[key];
  return JSON.parse(JSON.parse(raw));
}

/// Every stored key whose name ends with [suffix], across both web stores.
export function keysEndingWith(storage, suffix) {
  return [
    ...Object.keys(storage.local),
    ...Object.keys(storage.session),
  ].filter((key) => key.endsWith(suffix));
}

/// Flattens all stored keys and values into one lowercase blob, so an
/// assertion can prove a token shape appears nowhere at all.
export function storageBlob(storage) {
  return JSON.stringify([storage.local, storage.session, storage.databases])
    .toLowerCase();
}
