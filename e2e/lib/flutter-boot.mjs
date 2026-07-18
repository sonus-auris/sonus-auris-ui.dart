// Shared, driver-agnostic helpers for driving the built Flutter web app.
//
// Flutter web renders to canvas, so visible text is NOT in the DOM until the
// accessibility (semantics) tree is enabled. These helpers boot the app, turn
// on semantics, and read the resulting aria-labelled tree — the same technique
// both the Puppeteer and Playwright suites use so assertions stay identical.
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/// The built web bundle produced by `flutter build web --release`.
export const WEB_DIR = join(here, '..', '..', 'build', 'web');

/// Where screenshots land (uploaded as CI artifacts).
export const ARTIFACT_DIR = join(here, '..', 'artifacts');

export const EXPECTED_TITLE = 'Sonus Auris Console';

/// Console messages that indicate a genuine boot failure (as opposed to the
/// benign warnings Flutter/CanvasKit emit).
const FATAL_CONSOLE = [
  /Failed to load/i,
  /Uncaught/i,
  /TypeError/i,
  /is not a function/i,
  /CanvasKit.*failed/i,
];

export function isFatalConsole(text) {
  return FATAL_CONSOLE.some((re) => re.test(text));
}

/// Page-side script: waits until Flutter has mounted its render host, then
/// turns on the semantics tree so text becomes queryable in the DOM.
export const ENABLE_SEMANTICS_SCRIPT = `
  (async () => {
    const deadline = Date.now() + 30000;
    // Wait for Flutter to attach its glass pane / flutter-view.
    while (Date.now() < deadline) {
      if (document.querySelector('flt-glass-pane') ||
          document.querySelector('flutter-view') ||
          document.querySelector('flt-scene-host')) {
        break;
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    // Click the hidden "Enable accessibility" placeholder Flutter injects.
    const placeholder =
      document.querySelector('flt-semantics-placeholder') ||
      document.querySelector('[aria-label="Enable accessibility"]');
    if (placeholder) {
      placeholder.click();
      if (typeof placeholder.dispatchEvent === 'function') {
        placeholder.dispatchEvent(new Event('click', { bubbles: true }));
      }
    }
    return true;
  })()
`;

/// Page-side script: collects all aria-labels + text from the semantics tree.
export const READ_SEMANTICS_TEXT = `
  (() => {
    const nodes = Array.from(document.querySelectorAll('flt-semantics, [aria-label], [role]'));
    const labels = nodes.map((n) => n.getAttribute('aria-label') || n.textContent || '');
    return labels.join(' \\n ').trim();
  })()
`;

/// True once the Flutter render host exists in the DOM.
export const HAS_FLUTTER_HOST = `
  Boolean(document.querySelector('flt-glass-pane') ||
          document.querySelector('flutter-view') ||
          document.querySelector('flt-scene-host'))
`;

/// Polls [readText] (an async () => string) until [pattern] matches or timeout.
export async function waitForSemanticText(readText, pattern, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    last = (await readText()) ?? '';
    if (pattern.test(last)) {
      return last;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(
    `semantics text never matched ${pattern}. Last seen: ${last.slice(0, 400)}`,
  );
}
