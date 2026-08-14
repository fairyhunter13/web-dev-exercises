/**
 * Level 2 — fix `delay(ms)` using promises.
 *
 * Paste this whole file into any JS playground and press Run.
 *
 * The fix is one line: return a promise that resolves when the timer fires.
 * `setTimeout` takes `resolve` directly, so there is no closure to capture.
 */
function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// The call from the question. `alert` only exists in a browser, so fall back to
// `console.log` when this runs under Node. The promise behaviour is identical.
/* v8 ignore next */
const notify = typeof alert === 'function' ? alert : console.log;

// Skipped under the test runner so the demo's real 3s timer does not fire in the
// middle of a test that has installed fake ones. `process` is undefined in a
// browser playground, so the demo still runs when this file is pasted in. It
// reads as uncovered for the same reason, and it is not: the block in ANSWERS.md
// is run by scripts/run-answer-snippets.sh.
/* v8 ignore start */
if (typeof process === 'undefined' || !process.env.VITEST) {
  delay(3000).then(() => notify('runs after 3 seconds'));
}
/* v8 ignore stop */

// Two additions for anything beyond a demo.

/** Cancellable, so a pending delay does not keep a caller alive after abort. */
function cancellableDelay(ms, { signal } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);

    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      'abort',
      () => {
        clearTimeout(timer);
        reject(signal.reason);
      },
      { once: true },
    );
  });
}

// Node 24 and modern browsers ship this already:
//   const { promise, resolve } = Promise.withResolvers();
// and Node also has `timers/promises`:
//   import { setTimeout as delay } from 'node:timers/promises';

// Only the Node side of this guard runs under the test runner; the other side
// is what makes the file paste into a browser playground.
/* v8 ignore next */
if (typeof module !== 'undefined') module.exports = { delay, cancellableDelay };
