package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"slices"
	"strings"
	"testing"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

// TestConnectPostsNothing guards the bug this handshake exists to avoid.
//
// API Gateway answers 410 Gone to anything posted to a connection whose
// $connect handler has not returned yet. Because a 410 is how a genuinely dead
// peer is reported, the reaping logic then deleted the row Connect had just
// written, leaving an empty registry: messages were stored and delivered to
// nobody, with no error logged anywhere. A post from Connect must therefore
// never come back.
func TestConnectPostsNothing(t *testing.T) {
	r, store, poster := newRouter()
	store.messages = []chat.Message{{ID: "old", Author: "Alice", Body: "earlier"}}

	if err := r.Connect(context.Background(), "c1"); err != nil {
		t.Fatalf("Connect: %v", err)
	}

	if got := poster.typesFor("c1"); got != nil {
		t.Fatalf("frames = %v, want none until hello", got)
	}
	if !slices.Equal(store.conns, []string{"c1"}) {
		t.Fatalf("connections = %v, want the connection registered", store.conns)
	}
}

func TestHelloSendsHistoryThenPresence(t *testing.T) {
	r, store, poster := newRouter()
	store.messages = []chat.Message{{ID: "old", Author: "Alice", Body: "earlier"}}
	connectAll(t, r, poster, "c1")

	if err := r.Message(context.Background(), "c1", []byte(`{"type":"hello"}`)); err != nil {
		t.Fatalf("hello: %v", err)
	}

	// Order matters: a client told "1 window connected" before it has the
	// transcript renders an empty room for a beat.
	if got := poster.typesFor("c1"); !slices.Equal(got, []string{chat.TypeHistory, chat.TypePresence}) {
		t.Fatalf("frames = %v, want history then presence", got)
	}
	if got := poster.sent["c1"][0].Messages; len(got) != 1 || got[0].ID != "old" {
		t.Fatalf("history = %+v, want the one stored message", got)
	}
	if got := poster.sent["c1"][1].Count; got != 1 {
		t.Fatalf("presence count = %d, want 1", got)
	}
}

func TestHelloSurvivesHistoryFailure(t *testing.T) {
	// Dropping the socket because the transcript could not be read would turn a
	// recoverable read error into a client that cannot chat at all.
	r, store, poster := newRouter()
	store.recentErr = errors.New("dynamo unavailable")
	connectAll(t, r, poster, "c1")

	if err := r.Message(context.Background(), "c1", []byte(`{"type":"hello"}`)); err != nil {
		t.Fatalf("hello: %v", err)
	}
	if got := poster.sent["c1"][0].Messages; got != nil {
		t.Fatalf("history = %+v, want empty", got)
	}
}

func TestMessageBroadcastsToEveryone(t *testing.T) {
	r, store, poster := newRouter()
	connectAll(t, r, poster, "c1", "c2")

	mustSend(t, r, "c1", "Alice", "hello")

	// Including the sender: the client renders an optimistic copy and replaces
	// it with this echo, which is how it learns the server-assigned id.
	for _, id := range []string{"c1", "c2"} {
		frames := poster.sent[id]
		if len(frames) != 1 || frames[0].Type != chat.TypeMessage {
			t.Fatalf("%s got %v, want one message frame", id, poster.typesFor(id))
		}
		if got := frames[0].Message.Body; got != "hello" {
			t.Fatalf("%s body = %q", id, got)
		}
	}
	if len(store.messages) != 1 {
		t.Fatalf("stored %d messages, want 1", len(store.messages))
	}
}

func TestGoneConnectionIsReaped(t *testing.T) {
	// The registry only shrinks when a POST fails, so a missing reap means
	// every future broadcast pays for a connection that will never answer.
	r, store, poster := newRouter()
	connectAll(t, r, poster, "c1", "c2")
	poster.gone["c2"] = true

	mustSend(t, r, "c1", "Alice", "hello")

	if !slices.Equal(store.conns, []string{"c1"}) {
		t.Fatalf("connections = %v, want the dead one removed", store.conns)
	}
	if len(poster.sent["c1"]) == 0 {
		t.Fatal("delivery to the live connection was skipped")
	}
}

func TestInvalidFramesAnswerTheSenderWithoutFailing(t *testing.T) {
	// Returning an error would make Lambda retry a frame that cannot ever
	// become valid, and the retry would be billed.
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{"not json", `{`, "malformed frame"},
		{"unknown type", `{"type":"shout"}`, "unknown frame type"},
		{"no author", `{"type":"send","body":"hi"}`, chat.ErrNoAuthor.Error()},
		{"empty body", `{"type":"send","author":"Alice","body":"   "}`, chat.ErrEmptyBody.Error()},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r, store, poster := newRouter()
			connectAll(t, r, poster, "c1")

			if err := r.Message(context.Background(), "c1", []byte(tc.raw)); err != nil {
				t.Fatalf("Message returned %v, want nil", err)
			}
			frames := poster.sent["c1"]
			if len(frames) != 1 || frames[0].Type != chat.TypeError || frames[0].Error != tc.want {
				t.Fatalf("frames = %+v, want one error frame %q", frames, tc.want)
			}
			if len(store.messages) != 0 {
				t.Fatalf("stored %d messages, want none", len(store.messages))
			}
		})
	}
}

func TestPingIsAnsweredOnlyToTheSender(t *testing.T) {
	// Heartbeats are billed per message, so a pong that fanned out would
	// multiply the cost of keeping N idle windows open by N.
	r, _, poster := newRouter()
	connectAll(t, r, poster, "c1", "c2")

	if err := r.Message(context.Background(), "c1", []byte(`{"type":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	if got := poster.typesFor("c1"); !slices.Equal(got, []string{chat.TypePong}) {
		t.Fatalf("sender got %v, want pong", got)
	}
	if got := poster.typesFor("c2"); got != nil {
		t.Fatalf("peer got %v, want nothing", got)
	}
}

func TestConnectPropagatesStoreError(t *testing.T) {
	r, store, _ := newRouter()
	want := errors.New("dynamo unavailable")
	store.addErr = want

	err := r.Connect(context.Background(), "c1")
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestDisconnectPropagatesRemoveConnectionError(t *testing.T) {
	r, store, poster := newRouter()
	connectAll(t, r, poster, "c1")
	want := errors.New("dynamo unavailable")
	store.removeErr = want

	err := r.Disconnect(context.Background(), "c1")
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestDisconnectPropagatesConnectionsListError(t *testing.T) {
	// The presence broadcast that follows a successful removal must still
	// surface a failure to list the survivors.
	r, store, poster := newRouter()
	connectAll(t, r, poster, "c1", "c2")
	want := errors.New("dynamo unavailable")
	store.connsErr = want

	err := r.Disconnect(context.Background(), "c1")
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestMessageBroadcastPropagatesConnectionsListError(t *testing.T) {
	r, store, poster := newRouter()
	connectAll(t, r, poster, "c1")
	want := errors.New("dynamo unavailable")
	store.connsErr = want

	raw, err := json.Marshal(chat.Inbound{Type: chat.TypeSend, Author: "Alice", Body: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Message(context.Background(), "c1", raw); !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

// TestLoggerUsesInjectedLog covers logger()'s non-default branch: production
// wires a shared *slog.Logger through Router.Log so history-read failures land
// in the same log stream as everything else, instead of going to slog.Default.
func TestLoggerUsesInjectedLog(t *testing.T) {
	var buf bytes.Buffer
	r, store, poster := newRouter()
	r.Log = slog.New(slog.NewTextHandler(&buf, nil))
	store.recentErr = errors.New("dynamo unavailable")
	connectAll(t, r, poster, "c1")

	if err := r.Message(context.Background(), "c1", []byte(`{"type":"hello"}`)); err != nil {
		t.Fatalf("hello: %v", err)
	}
	if !strings.Contains(buf.String(), "history read failed") {
		t.Fatalf("log output = %q, want it to contain the warning", buf.String())
	}
}

func TestFanOutJoinsAllFailures(t *testing.T) {
	// A second dead peer must not be swallowed by the first: fanOut collects
	// every failure so nothing about a broadcast is silently half-delivered.
	r, store, poster := newRouter()
	store.messages = nil
	connectAll(t, r, poster, "c1", "c2", "c3")
	errA := errors.New("boom a")
	errB := errors.New("boom b")
	poster.fail["c2"] = errA
	poster.fail["c3"] = errB

	err := r.Disconnect(context.Background(), "c1")
	if err == nil {
		t.Fatal("want an error, got nil")
	}
	if !errors.Is(err, errA) || !errors.Is(err, errB) {
		t.Fatalf("err = %v, want both underlying failures present", err)
	}
}

func TestSendErrorPropagatesNonGoneFailure(t *testing.T) {
	// sendError swallows ErrGone, since a disconnected peer is not worth
	// reporting as an invocation failure; anything else must still surface.
	r, _, poster := newRouter()
	connectAll(t, r, poster, "c1")
	failErr := errors.New("management api unavailable")
	poster.fail["c1"] = failErr

	err := r.Message(context.Background(), "c1", []byte(`{"type":"shout"}`))
	if !errors.Is(err, failErr) {
		t.Fatalf("err = %v, want %v", err, failErr)
	}
}

func TestDisconnectRemovesAndRepublishesPresence(t *testing.T) {
	r, store, poster := newRouter()
	connectAll(t, r, poster, "c1", "c2")

	if err := r.Disconnect(context.Background(), "c2"); err != nil {
		t.Fatalf("Disconnect: %v", err)
	}
	if !slices.Equal(store.conns, []string{"c1"}) {
		t.Fatalf("connections = %v", store.conns)
	}
	frames := poster.sent["c1"]
	if len(frames) != 1 || frames[0].Type != chat.TypePresence || frames[0].Count != 1 {
		t.Fatalf("frames = %+v, want presence count 1", frames)
	}
}
