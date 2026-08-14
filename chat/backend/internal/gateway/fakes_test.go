package gateway

import (
	"context"
	"encoding/json"
	"slices"
	"testing"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

// fakeStore is an in-memory Store, not concurrency-safe. A Lambda invocation
// handles one route at a time, so a mutex here would only hide a routing bug
// that fanned out from two goroutines.
type fakeStore struct {
	conns     []string
	messages  []chat.Message
	recentErr error
	addErr    error
	removeErr error
	connsErr  error
}

func (s *fakeStore) AddConnection(_ context.Context, id string) error {
	if s.addErr != nil {
		return s.addErr
	}
	if !slices.Contains(s.conns, id) {
		s.conns = append(s.conns, id)
	}
	return nil
}

func (s *fakeStore) RemoveConnection(_ context.Context, id string) error {
	if s.removeErr != nil {
		return s.removeErr
	}
	s.conns = slices.DeleteFunc(s.conns, func(c string) bool { return c == id })
	return nil
}

func (s *fakeStore) Connections(context.Context) ([]string, error) {
	if s.connsErr != nil {
		return nil, s.connsErr
	}
	return slices.Clone(s.conns), nil
}

func (s *fakeStore) AppendMessage(_ context.Context, m chat.Message) error {
	s.messages = append(s.messages, m)
	return nil
}

func (s *fakeStore) Recent(_ context.Context, limit int) ([]chat.Message, error) {
	if s.recentErr != nil {
		return nil, s.recentErr
	}
	if len(s.messages) > limit {
		return slices.Clone(s.messages[len(s.messages)-limit:]), nil
	}
	return slices.Clone(s.messages), nil
}

// fakePoster records every frame per connection, and can be told a connection
// is gone, the GoneException case, or made to fail outright for some other
// reason (a throttled or unreachable management API, say).
type fakePoster struct {
	sent map[string][]chat.Outbound
	gone map[string]bool
	fail map[string]error
}

func newPoster() *fakePoster {
	return &fakePoster{sent: map[string][]chat.Outbound{}, gone: map[string]bool{}, fail: map[string]error{}}
}

func (p *fakePoster) Post(_ context.Context, id string, payload []byte) error {
	if p.gone[id] {
		return ErrGone
	}
	if err := p.fail[id]; err != nil {
		return err
	}
	var frame chat.Outbound
	if err := json.Unmarshal(payload, &frame); err != nil {
		return err
	}
	p.sent[id] = append(p.sent[id], frame)
	return nil
}

func (p *fakePoster) typesFor(id string) []string {
	var out []string
	for _, f := range p.sent[id] {
		out = append(out, f.Type)
	}
	return out
}

func (p *fakePoster) reset() { p.sent = map[string][]chat.Outbound{} }

func newRouter() (*Router, *fakeStore, *fakePoster) {
	store, poster := &fakeStore{}, newPoster()
	n := 0
	return &Router{
		Store:  store,
		Poster: poster,
		NewID:  func() string { n++; return "m" + string(rune('0'+n)) },
		NowMS:  func() int64 { return 1_700_000_000_000 },
	}, store, poster
}

// connectAll opens the given connections and clears the frames they triggered,
// so each test asserts only on what it does itself.
func connectAll(t *testing.T, r *Router, p *fakePoster, ids ...string) {
	t.Helper()
	for _, id := range ids {
		if err := r.Connect(context.Background(), id); err != nil {
			t.Fatalf("Connect(%s): %v", id, err)
		}
	}
	p.reset()
}

func mustSend(t *testing.T, r *Router, conn, author, body string) {
	t.Helper()
	raw, err := json.Marshal(chat.Inbound{Type: chat.TypeSend, Author: author, Body: body})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Message(context.Background(), conn, raw); err != nil {
		t.Fatalf("Message: %v", err)
	}
}
