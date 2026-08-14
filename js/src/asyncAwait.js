/**
 * Level 2.5 — rewrite the callback chain using async/await.
 *
 * Paste this whole file into any JS playground and press Run.
 *
 * Three things change:
 *
 *  1. The nesting disappears. The callback version puts the happy path two
 *     levels deep and repeats the error handling at every level; the async
 *     version is flat with one `catch`.
 *  2. Errors become real errors. The originals call back with a string
 *     ("URL is required"), which has no stack and no `catch` can see it.
 *     Rejecting with an `Error` fixes both.
 *  3. The callbacks are wrapped once at the boundary. `fetchData` and
 *     `processData` are left exactly as the question gave them, which is the
 *     refactor you would do against code you do not own.
 */

// --- unchanged from the question -------------------------------------------
function fetchData(url, callback) {
  setTimeout(() => {
    if (!url) {
      callback("URL is required", null);
    } else {
      callback(null, `Data from ${url}`);
    }
  }, 1000);
}


function processData(data, callback) {
  setTimeout(() => {
    if (!data) {
      callback("Data is required", null);
    } else {
      callback(null, data.toUpperCase());
    }
  }, 1000);
}

// --- the rewrite ------------------------------------------------------------

/**
 * Wraps any Node-style `(arg, callback(err, value))` function so it returns a
 * promise. Node's `util.promisify` does the same thing; it is inlined here so
 * the file runs unchanged in a browser playground.
 */
const promisify =
  (fn) =>
  (...args) =>
    new Promise((resolve, reject) => {
      fn(...args, (err, value) => (err ? reject(new Error(err)) : resolve(value)));
    });

const fetchDataAsync = promisify(fetchData);
const processDataAsync = promisify(processData);

// The demo from here down is skipped under the test runner, so it reads as
// uncovered. It is not: the block in ANSWERS.md is run by
// scripts/run-answer-snippets.sh.
/* v8 ignore start */
async function main() {
  try {
    const data = await fetchDataAsync('https://example.com');
    const processed = await processDataAsync(data);
    console.log('Processed Data:', processed);
  } catch (error) {
    console.error('Error:', error.message);
  }
}

// Skipped under the test runner so the demo's real timers do not fire in the
// middle of a test that has installed fake ones. `process` is undefined in a
// browser playground, so the demo still runs when this file is pasted in.
if (typeof process === 'undefined' || !process.env.VITEST) {
  main();
  // Processed Data: DATA FROM HTTPS://EXAMPLE.COM

  // The error path, to show the single `catch` covers both stages. It prints
  // first because it waits on one 1s timer, not two.
  fetchDataAsync('')
    .then((d) => console.log('unexpected success:', d))
    .catch((e) => console.error('Error:', e.message)); // Error: URL is required
}
/* v8 ignore stop */

// Only the Node side of this guard runs under the test runner; the other side
// is what makes the file paste into a browser playground.
/* v8 ignore next */
if (typeof module !== 'undefined') {
  module.exports = { fetchData, processData, fetchDataAsync, processDataAsync, promisify };
}
