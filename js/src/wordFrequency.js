/**
 * Level 1 (alternative) — word frequency, case insensitive, punctuation ignored.
 *
 * Paste this whole file into any JS playground and press Run.
 *
 * A Map keeps words like "constructor", "__proto__" and "toString" from
 * colliding with an object's inherited properties.
 *
 * Apostrophes are the one exception to "ignore punctuation". They are allowed
 * inside a word, so "don't" counts as one word, but a word may only start on a
 * letter or a digit, so a quoted 'word' is not distinct.
 *
 * Digits may start a word so that "3rd" counts as "3rd" rather than "rd". The
 * Go answer to the same question does the same, and js/test and go/wordfreq run
 * the same table of cases to keep them from drifting apart.
 */
function wordFrequency(input) {
  const counts = new Map();

  for (const [word] of String(input).matchAll(/[\p{L}\p{N}][\p{L}\p{M}\p{N}'’]*/gu)) {
    const key = word.toLowerCase().replace(/['’]+$/u, '');
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }

  return counts;
}

// The string from the question. The runs of two and three spaces near the end
// and the mixed casing of "three"/"Three" are what it tests. The Go version of
// the same question adds a comma after "Four", so the pattern strips
// punctuation instead of splitting on whitespace.
const input = 'Four One two two three Three three four  four   four';

// Skipped under the test runner; `process` does not exist in a browser, so the
// demo still runs when this file is pasted into a playground. It reads as
// uncovered for the same reason, and it is not: the block in ANSWERS.md is run
// by scripts/run-answer-snippets.sh.
/* v8 ignore start */
if (typeof process === 'undefined' || !process.env.VITEST) {
  // A Map iterates in insertion order, so this prints first-seen first.
  for (const [word, count] of wordFrequency(input)) {
    console.log(`${word} => ${count}`);
  }
  // four => 4
  // one => 1
  // two => 2
  // three => 3
}
/* v8 ignore stop */

// Only the Node side of this guard runs under the test runner; the other side
// is what makes the file paste into a browser playground.
/* v8 ignore next */
if (typeof module !== 'undefined') module.exports = { wordFrequency };
