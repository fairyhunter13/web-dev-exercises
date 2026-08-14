// Word frequency counter — case insensitive, punctuation ignored.
//
// Runs as-is on https://goplay.tools/ (or the official Go playground):
// copy this whole file in and press Run.
package main

import (
	"fmt"
	"maps"
	"slices"
	"strings"
	"unicode"
)

// WordFrequency counts how often each word appears in s, case-insensitively,
// ignoring punctuation.
//
// Splitting uses strings.FieldsFunc. strings.Fields splits on whitespace only,
// which would leave "Four," attached to its comma and produce a separate
// "four," entry. FieldsFunc also collapses runs of separators, so the double
// and triple spaces in the sample input cost nothing.
//
// Apostrophes are the one exception to "ignore punctuation". They are allowed
// inside a word, so "don't" counts as one word, and are trimmed from the edges,
// so a quoted 'word' does not become its own entry.
//
// Combining marks are not separators either. unicode.IsLetter is false for
// them, so without this an "é" written in decomposed form ("e" plus U+0301)
// would split into "e" and be counted as a different word from the composed
// form. The JS answer to the same question keeps them via \p{M}, and both
// suites run the same table of cases so the two cannot drift apart.
func WordFrequency(s string) map[string]int {
	const apostrophes = "'’"

	isSeparator := func(r rune) bool {
		if strings.ContainsRune(apostrophes, r) {
			return false
		}
		return !unicode.IsLetter(r) && !unicode.IsDigit(r) && !unicode.Is(unicode.M, r)
	}

	counts := make(map[string]int)
	for _, field := range strings.FieldsFunc(s, isSeparator) {
		word := strings.Trim(field, apostrophes)
		if word == "" {
			continue
		}
		counts[strings.ToLower(word)]++
	}
	return counts
}

func main() {
	const input = "Four, One two two three Three three four  four   four"

	counts := WordFrequency(input)

	// Map iteration order in Go is deliberately randomised, so sort the keys to
	// make the output reproducible. slices.Sorted consumes the iterator that
	// maps.Keys returns (Go 1.23+); it does not take a slice.
	for _, word := range slices.Sorted(maps.Keys(counts)) {
		fmt.Printf("%s => %d\n", word, counts[word])
	}
}
