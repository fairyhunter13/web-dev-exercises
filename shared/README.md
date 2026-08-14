# shared/

`wordfreq-cases.json` is one table of cases run by two suites:
`js/test/wordFrequency.test.js` and `go/wordfreq/main_test.go`.

The word-frequency question is answered twice, once in JavaScript and once in Go, and the two
answers used to disagree on input the question itself does not contain: a word starting with a
digit, and an accent written in decomposed form. Both are fixed, and this file is how they stay
fixed. A case added here has to pass in both languages.

JSON has no comments, so two of the cases need a note. `Café` appears twice, once as `é`
(U+00E9) and once as `e` followed by U+0301. They look identical and are different strings.
`𐐀𐐩` is Deseret, outside the basic plane, so it is a surrogate pair in JavaScript and four
bytes in Go.
