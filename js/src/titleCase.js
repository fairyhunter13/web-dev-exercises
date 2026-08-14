/**
 * Level 1 — Title Case
 *
 * Paste this whole file into any JS playground and press Run.
 *
 * Why match words instead of `split(" ")`:
 *  - `split(" ")` produces empty strings for runs of spaces, and `w[0]` on an
 *    empty string is `undefined`, which throws. It also normalises the original
 *    spacing, so "a  b" would come back as "a b".
 *  - Replacing matches leaves every separator (spaces, tabs, newlines,
 *    hyphens, punctuation) exactly where it was.
 *
 * Why `\p{L}` and not `\w`:
 *  - `\w` is ASCII-only, so "mère" would be treated as "m" + "re".
 *  - The classic `\b\w` trick also capitalises after an apostrophe: "don't"
 *    becomes "Don'T". Allowing apostrophes *inside* the match fixes that.
 *
 * Hyphen rule chosen here: both sides are capitalised, so "tea-pot" becomes
 * "Tea-Pot". Style guides differ on this one.
 */
function titleCase(input) {
  return String(input).replace(/\p{L}[\p{L}\p{M}'’]*/gu, (word) => {
    // Spreading iterates by code point, so astral-plane letters are not split
    // in half the way `word[0]` would split them.
    const [first, ...rest] = word;
    return first.toUpperCase() + rest.join('').toLowerCase();
  });
}

/**
 * An alternative that lets the platform decide what a word is.
 *
 * Intl.Segmenter implements UAX#29 word segmentation, which knows about
 * scripts that do not put spaces between words (Japanese, Thai, Khmer), where
 * the regex above sees one long "word" and capitalises only its first letter.
 *
 * On hyphens the two agree: Segmenter splits "tea-pot" into "tea", "-", "pot"
 * with both halves word-like, so this also returns "Tea-Pot".
 *
 * Not the primary answer because Segmenter needs a locale to be correct, and
 * picking one for arbitrary input is a guess.
 */
function titleCaseSegmenter(input, locale = 'en') {
  const segmenter = new Intl.Segmenter(locale, { granularity: 'word' });

  let out = '';
  for (const { segment, isWordLike } of segmenter.segment(String(input))) {
    if (!isWordLike) {
      out += segment; // punctuation and whitespace pass through untouched
      continue;
    }
    const [first, ...rest] = segment;
    out += first.toUpperCase() + rest.join('').toLowerCase();
  }
  return out;
}

// Skipped under the test runner, which asserts on return values. `process` does
// not exist in a browser, so pasting this file into a playground still runs the
// demo. It reads as uncovered for the same reason, and it is not: the block in
// ANSWERS.md is run by scripts/run-answer-snippets.sh.
/* v8 ignore start */
if (typeof process === 'undefined' || !process.env.VITEST) {
  // The four cases from the question.
  console.log(typeof titleCase("I'm a little tea pot")); // "string"
  console.log(titleCase("I'm a little tea pot")); // I'm A Little Tea Pot
  console.log(titleCase('sHoRt AnD sToUt')); // Short And Stout
  console.log(titleCase('SHORT AND STOUT')); // Short And Stout

  // Cases the three above do not cover.
  console.log(JSON.stringify(titleCase('  hello   world  '))); // spacing preserved
  console.log(titleCase("don't stop")); // Don't Stop, not Don'T Stop
  console.log(titleCase('mère et père')); // Mère Et Père

  // The Segmenter variant agrees on hyphens and differs on scripts that do not
  // separate words with spaces.
  console.log(titleCase('tea-pot'), titleCaseSegmenter('tea-pot')); // Tea-Pot Tea-Pot
}
/* v8 ignore stop */

// Only the Node side of this guard runs under the test runner; the other side
// is what makes the file paste cleanly into a browser playground.
/* v8 ignore next */
if (typeof module !== 'undefined') module.exports = { titleCase, titleCaseSegmenter };
