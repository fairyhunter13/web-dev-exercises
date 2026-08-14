package chat

import (
	"errors"
	"strings"
	"sync"
	"testing"
)

// fakeSink records what it was sent, and can be told to fail, which is how the
// GoneException path on API Gateway is simulated without an API Gateway.
type fakeSink struct {
	mu       sync.Mutex
	id       string
	received []Outbound
	fail     error
}

func (f *fakeSink) ID() string { return f.id }

func (f *fakeSink) Send(o Outbound) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail != nil {
		return f.fail
	}
	f.received = append(f.received, o)
	return nil
}

func (f *fakeSink) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.received)
}

func TestBroadcastReachesEveryClient(t *testing.T) {
	h := NewHub()
	a, b := &fakeSink{id: "a"}, &fakeSink{id: "b"}
	h.Join(a)
	h.Join(b)

	// The sender is included. The client renders an optimistic copy
	// immediately and reconciles it against the broadcast using clientId, so
	// echoing back to the sender is what confirms the server accepted it.
	if failed := h.Broadcast(Outbound{Type: TypeMessage, Message: &Message{ID: "1", Body: "hi"}}); failed != nil {
		t.Fatalf("unexpected failures: %v", failed)
	}
	if a.count() != 1 || b.count() != 1 {
		t.Fatalf("want both clients to receive 1 frame, got a=%d b=%d", a.count(), b.count())
	}
}

func TestBroadcastDropsClientsThatFail(t *testing.T) {
	h := NewHub()
	var gone []string
	h.GoneFunc = func(id string) { gone = append(gone, id) }

	ok := &fakeSink{id: "ok"}
	dead := &fakeSink{id: "dead", fail: errors.New("GoneException")}
	h.Join(ok)
	h.Join(dead)

	failed := h.Broadcast(Outbound{Type: TypeMessage, Message: &Message{ID: "1"}})

	if len(failed) != 1 || failed[0] != "dead" {
		t.Fatalf("want [dead] reported as failed, got %v", failed)
	}
	if h.Count() != 1 {
		t.Fatalf("want the dead client evicted, hub still has %d clients", h.Count())
	}
	if len(gone) != 1 || gone[0] != "dead" {
		t.Fatalf("want GoneFunc called for dead, got %v", gone)
	}
	// A failing peer must not stop the healthy one from receiving.
	if ok.count() != 1 {
		t.Fatalf("want the healthy client to still receive, got %d frames", ok.count())
	}
}

func TestJoinReturnsHistoryAndRecentIsBounded(t *testing.T) {
	h := NewHub()
	for i := range HistoryLimit + 10 {
		h.Record(Message{ID: string(rune('a' + i%26)), Body: "m"})
	}

	if got := len(h.Recent()); got != HistoryLimit {
		t.Fatalf("want the buffer trimmed to %d, got %d", HistoryLimit, got)
	}

	late := &fakeSink{id: "late"}
	history := h.Join(late)
	if len(history) != HistoryLimit {
		t.Fatalf("want a reconnecting client to get %d messages, got %d", HistoryLimit, len(history))
	}
}

func TestRecentIsACopy(t *testing.T) {
	// Handing out the internal slice would let a caller mutate hub state
	// through it, and would race with Record.
	h := NewHub()
	h.Record(Message{ID: "1", Body: "original"})

	snapshot := h.Recent()
	snapshot[0].Body = "mutated"

	if h.Recent()[0].Body != "original" {
		t.Fatal("Recent returned the internal slice; a caller can corrupt hub state")
	}
}

func TestLeaveIsIdempotent(t *testing.T) {
	// A disconnect can be noticed by the read loop and by a failed broadcast at
	// the same time, so double-leave has to be harmless.
	h := NewHub()
	h.Join(&fakeSink{id: "a"})
	h.Leave("a")
	h.Leave("a")
	h.Leave("never-existed")
	if h.Count() != 0 {
		t.Fatalf("want 0 clients, got %d", h.Count())
	}
}

func TestConcurrentJoinBroadcastLeave(t *testing.T) {
	// Run with -race. The hub is touched from one goroutine per connection in
	// the real server, so the race detector is the actual assertion here.
	h := NewHub()
	var wg sync.WaitGroup
	for i := range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s := &fakeSink{id: string(rune('A'+i%26)) + string(rune('0'+i/26))}
			h.Join(s)
			h.Record(Message{ID: s.id})
			h.Broadcast(Outbound{Type: TypePresence, Count: h.Count()})
			h.Leave(s.id)
		}()
	}
	wg.Wait()
	if h.Count() != 0 {
		t.Fatalf("want every client to have left, got %d", h.Count())
	}
}

func TestBroadcastPresenceReportsCount(t *testing.T) {
	h := NewHub()
	a, b := &fakeSink{id: "a"}, &fakeSink{id: "b"}
	h.Join(a)
	h.Join(b)

	h.BroadcastPresence()

	for _, s := range []*fakeSink{a, b} {
		if s.count() != 1 {
			t.Fatalf("%s got %d frames, want 1", s.id, s.count())
		}
		got := s.received[0]
		if got.Type != TypePresence || got.Count != 2 {
			t.Fatalf("frame = %+v, want presence with count 2", got)
		}
	}
}

func TestBroadcastWithNilGoneFuncDoesNotPanic(t *testing.T) {
	// GoneFunc is optional: the local server has no reaping side effect to
	// register, and Broadcast must not assume every caller sets one.
	h := NewHub()
	h.Join(&fakeSink{id: "dead", fail: errors.New("boom")})

	failed := h.Broadcast(Outbound{Type: TypeMessage})

	if len(failed) != 1 || failed[0] != "dead" {
		t.Fatalf("failed = %v, want [dead]", failed)
	}
	if h.Count() != 0 {
		t.Fatalf("want the dead client evicted, hub still has %d clients", h.Count())
	}
}

func TestValidate(t *testing.T) {
	long := make([]rune, MaxBodyRunes+1)
	for i := range long {
		long[i] = 'x'
	}

	tests := map[string]struct {
		in         Inbound
		wantErr    error
		wantAuthor string
		wantBody   string
	}{
		"trims whitespace": {
			in:         Inbound{Author: "  Hafiz  ", Body: "  hello  "},
			wantAuthor: "Hafiz", wantBody: "hello",
		},
		"rejects an empty body": {
			in: Inbound{Author: "Hafiz", Body: "   "}, wantErr: ErrEmptyBody,
		},
		"rejects a missing author": {
			in: Inbound{Author: " ", Body: "hello"}, wantErr: ErrNoAuthor,
		},
		"rejects an over-long body": {
			in: Inbound{Author: "Hafiz", Body: string(long)}, wantErr: ErrBodyTooLong,
		},
		"counts runes, not bytes": {
			// 4 characters, 12 bytes. A byte-based cap would treat this as
			// three times longer than it is.
			in:         Inbound{Author: "Hafiz", Body: "こんにちは"},
			wantAuthor: "Hafiz", wantBody: "こんにちは",
		},
		"truncates an over-long author at the rune boundary": {
			// Every rune is 3 bytes, so a byte-based truncation would cut mid
			// character and produce invalid UTF-8; a rune-based one lands
			// cleanly on MaxAuthorRunes characters.
			in:         Inbound{Author: strings.Repeat("あ", MaxAuthorRunes+5), Body: "hi"},
			wantAuthor: strings.Repeat("あ", MaxAuthorRunes), wantBody: "hi",
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			author, body, err := tc.in.Validate()
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
			if tc.wantErr != nil {
				return
			}
			if author != tc.wantAuthor || body != tc.wantBody {
				t.Fatalf("got (%q, %q), want (%q, %q)", author, body, tc.wantAuthor, tc.wantBody)
			}
		})
	}
}
