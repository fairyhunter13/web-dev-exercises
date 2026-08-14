import { describe, expect, it } from 'vitest';
import { titleCase, titleCaseSegmenter } from '../src/titleCase.js';

describe('titleCase', () => {
  it('returns a string', () => {
    expect(typeof titleCase("I'm a little tea pot")).toBe('string');
  });

  // The three cases the question lists explicitly.
  it.each([
    ["I'm a little tea pot", "I'm A Little Tea Pot"],
    ['sHoRt AnD sToUt', 'Short And Stout'],
    ['SHORT AND STOUT', 'Short And Stout'],
  ])('titleCase(%j) === %j', (input, expected) => {
    expect(titleCase(input)).toBe(expected);
  });

  it('does not capitalise the letter after an apostrophe', () => {
    // The `\b\w` approach that most answers use returns "Don'T Stop" here.
    expect(titleCase("don't stop")).toBe("Don't Stop");
    expect(titleCase('don’t stop')).toBe('Don’t Stop');
  });

  it('preserves the original whitespace exactly', () => {
    // `split(" ")` collapses these runs, and throws on the empty strings it
    // produces at the ends.
    expect(titleCase('  hello   world  ')).toBe('  Hello   World  ');
    expect(titleCase('a\tb\nc')).toBe('A\tB\nC');
  });

  it('handles non-ASCII letters, which \\w does not', () => {
    expect(titleCase('mère et père')).toBe('Mère Et Père');
    expect(titleCase('ÅNGSTRÖM')).toBe('Ångström');
  });

  it('capitalises both sides of a hyphen', () => {
    // The pattern treats "-" as a separator. Intl.Segmenter's word
    // segmentation does the same.
    expect(titleCase('tea-pot')).toBe('Tea-Pot');
  });

  it('does not throw on empty or punctuation-only input', () => {
    expect(titleCase('')).toBe('');
    expect(titleCase('   ')).toBe('   ');
    expect(titleCase('!!! ...')).toBe('!!! ...');
  });

  it('leaves digits and symbols alone', () => {
    expect(titleCase('go 1.26 release')).toBe('Go 1.26 Release');
  });

  it('spreads by code point, so astral-plane letters are not split like word[0] would split them', () => {
    // U+10400 DESERET CAPITAL LETTER LONG I / U+10429 DESERET SMALL LETTER LONG A
    // are each a surrogate pair. `word[0]` would grab only the leading
    // surrogate, an invalid lone surrogate, and uppercase it as itself.
    expect(titleCase('𐐀𐐩 abc')).toBe('𐐀𐐩 Abc');
  });

  it('coerces non-string input via String(), including the surprising cases', () => {
    expect(titleCase(null)).toBe('Null');
    expect(titleCase(undefined)).toBe('Undefined');
    expect(titleCase(42)).toBe('42');
    expect(titleCase({})).toBe('[Object Object]');
  });

  it('is locale-insensitive, so Turkish dotted/dotless i and German ß are not handled specially', () => {
    // Locale-aware casing would turn dotless 'ı' into 'I' (not 'İ') and treat
    // 'İ' specially; the locale-insensitive toUpperCase/toLowerCase used here
    // does not.
    expect(titleCase('ıstanbul')).toBe('Istanbul');
    expect(titleCase('İstanbul')).toBe('İstanbul');
    // ß has no single-character uppercase in locale-insensitive mapping, so it
    // is left as-is rather than expanded to "SS".
    expect(titleCase('straße')).toBe('Straße');
  });

  it('keeps NFD combining marks attached to their base letter', () => {
    // "é" as e + U+0301 COMBINING ACUTE ACCENT (NFD), not the precomposed
    // U+00E9. \p{M} in the pattern is what keeps the combining mark inside the
    // match instead of splitting the word at it.
    const nfdEte = 'été'; // "été" decomposed
    expect(titleCase(nfdEte)).toBe('Été');
  });

  it('titleCaseSegmenter finds word boundaries the regex cannot see in scripts with no spaces', () => {
    // Kanji count as \p{L}, so the regex sees "tokyo東京ni" as one contiguous
    // word and only capitalises the leading "t"; the trailing "ni" stays
    // lowercase. Intl.Segmenter's UAX#29 word segmentation always splits at a
    // Han/Latin script boundary (that rule does not depend on a dictionary),
    // so it treats "ni" as its own word and capitalises it too.
    expect(titleCase('tokyo東京ni')).toBe('Tokyo東京ni');
    expect(titleCaseSegmenter('tokyo東京ni')).toBe('Tokyo東京Ni');
  });

  it('titleCaseSegmenter accepts a locale argument', () => {
    expect(titleCaseSegmenter('hello world', 'ja')).toBe('Hello World');
  });
});

describe('titleCaseSegmenter', () => {
  // The documented alternative. It has to agree with the regex on ordinary
  // input, or offering it as a variant would be offering a different function.
  it.each([
    ["I'm a little tea pot", "I'm A Little Tea Pot"],
    ['sHoRt AnD sToUt', 'Short And Stout'],
    ['SHORT AND STOUT', 'Short And Stout'],
    ['  hello   world  ', '  Hello   World  '],
    ["don't stop", "Don't Stop"],
    ['tea-pot', 'Tea-Pot'],
  ])('titleCaseSegmenter(%j) === %j', (input, expected) => {
    expect(titleCaseSegmenter(input)).toBe(expected);
  });

  it('agrees with the regex version on the question\'s cases', () => {
    for (const input of ["I'm a little tea pot", 'sHoRt AnD sToUt', 'SHORT AND STOUT']) {
      expect(titleCaseSegmenter(input)).toBe(titleCase(input));
    }
  });
});
