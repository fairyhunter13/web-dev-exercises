package main

import (
	"encoding/json"
	"io"
	"maps"
	"os"
	"testing"
)

func TestWordFrequency(t *testing.T) {
	tests := map[string]struct {
		input string
		want  map[string]int
	}{
		"the string from the question": {
			input: "Four, One two two three Three three four  four   four",
			want:  map[string]int{"one": 1, "two": 2, "three": 3, "four": 4},
		},
		"empty string": {
			input: "",
			want:  map[string]int{},
		},
		"punctuation only": {
			input: "!!! ... ,,,",
			want:  map[string]int{},
		},
		"punctuation is stripped from the edges": {
			input: "stop. Stop! 'stop'",
			want:  map[string]int{"stop": 3},
		},
		"apostrophes are kept inside a word": {
			input: "don't Don't dont",
			want:  map[string]int{"don't": 2, "dont": 1},
		},
		"digits count as word characters": {
			input: "go1 Go1 go2",
			want:  map[string]int{"go1": 2, "go2": 1},
		},
		"non-ASCII letters are letters": {
			input: "Café café CAFÉ",
			want:  map[string]int{"café": 3},
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			got := WordFrequency(tc.input)
			if !maps.Equal(got, tc.want) {
				t.Errorf("WordFrequency(%q)\n got: %v\nwant: %v", tc.input, got, tc.want)
			}
		})
	}
}

// The same question is answered in JavaScript as well, and the two answers
// used to disagree on input the question does not contain. Both run this table,
// so a case only passes if it passes in both languages. See shared/README.md.
func TestWordFrequencyMatchesTheJavaScriptAnswer(t *testing.T) {
	raw, err := os.ReadFile("../../shared/wordfreq-cases.json")
	if err != nil {
		t.Fatalf("read shared cases: %v", err)
	}

	var cases []struct {
		Name  string         `json:"name"`
		Input string         `json:"input"`
		Want  map[string]int `json:"want"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatalf("parse shared cases: %v", err)
	}
	if len(cases) == 0 {
		t.Fatal("shared cases file is empty")
	}

	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			got := WordFrequency(tc.Input)
			if !maps.Equal(got, tc.Want) {
				t.Errorf("WordFrequency(%q)\n got: %v\nwant: %v", tc.Input, got, tc.Want)
			}
		})
	}
}

// The doc comment on main promises the printed lines are sorted by key
// (via slices.Sorted(maps.Keys(counts))), not in map-iteration order, which
// Go deliberately randomises. Nothing else checks that claim.
func TestMainPrintsWordsSortedByKey(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}

	origStdout := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = origStdout }()

	main()

	if err := w.Close(); err != nil {
		t.Fatalf("close pipe writer: %v", err)
	}
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read pipe: %v", err)
	}

	want := "four => 4\none => 1\nthree => 3\ntwo => 2\n"
	if got := string(out); got != want {
		t.Errorf("main() output =\n%s\nwant:\n%s", got, want)
	}
}
