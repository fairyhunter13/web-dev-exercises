import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { wordFrequency } from '../src/wordFrequency.js';

const asObject = (map) => Object.fromEntries(map);

describe('wordFrequency', () => {
  it('counts the string from the question', () => {
    const input = 'Four One two two three Three three four  four   four';
    expect(asObject(wordFrequency(input))).toEqual({
      one: 1,
      two: 2,
      three: 3,
      four: 4,
    });
  });

  it('ignores punctuation, including the comma in the Go version of the string', () => {
    const input = 'Four, One two two three Three three four  four   four';
    expect(asObject(wordFrequency(input))).toEqual({
      one: 1,
      two: 2,
      three: 3,
      four: 4,
    });
  });

  it('is case insensitive', () => {
    expect(asObject(wordFrequency('Go GO go gO'))).toEqual({ go: 4 });
  });

  it('keeps apostrophes inside a word but not around it', () => {
    expect(asObject(wordFrequency("don't Don't 'dont'"))).toEqual({
      "don't": 2,
      dont: 1,
    });
  });

  it('returns an empty Map for input with no words', () => {
    expect(wordFrequency('').size).toBe(0);
    expect(wordFrequency('!!! ,,, ...').size).toBe(0);
  });

  it('uses a Map, so prototype keys cannot collide', () => {
    const counts = wordFrequency('constructor toString __proto__ constructor');
    expect(counts.get('constructor')).toBe(2);
    expect(counts.get('tostring')).toBe(1);
    expect(counts.get('proto')).toBe(1);
  });

  it('returns a Map', () => {
    expect(wordFrequency('go')).toBeInstanceOf(Map);
  });

  it('iterates in first-seen (insertion) order', () => {
    // Object.toEqual ignores key order, so the "prints first-seen first"
    // claim in the source comment needs its own assertion against the
    // iteration order, not against asObject().
    const input = 'Four One two two three Three three four  four   four';
    expect([...wordFrequency(input).keys()]).toEqual(['four', 'one', 'two', 'three']);
  });
});

// The same question is answered in Go as well, and the two answers used to
// disagree on input the question does not contain. Both run this table, so a
// case only passes if it passes in both languages. See shared/README.md.
describe('wordFrequency agrees with the Go answer', () => {
  const cases = JSON.parse(
    readFileSync(new URL('../../shared/wordfreq-cases.json', import.meta.url), 'utf8'),
  );

  it.each(cases)('$name', ({ input, want }) => {
    expect(asObject(wordFrequency(input))).toEqual(want);
  });
});
