// Package gateway holds the API Gateway WebSocket routing logic, kept free of
// any AWS SDK type so it can be unit-tested against fakes.
//
// Lambda cannot use the in-memory hub from package chat: every invocation is a
// separate process, and two concurrent messages may land on two different
// execution environments. The connection registry and the transcript therefore
// live in DynamoDB, and fan-out is an explicit POST to each connection through
// the @connections management API.
package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

// ErrGone reports that a connection no longer exists. API Gateway answers a
// POST to a dead connection with GoneException; the row must then be deleted,
// or the registry grows forever and every broadcast pays for the dead entries.
var ErrGone = errors.New("connection is gone")

// Store is the persistence the handlers need. Two tables back it: one for
// connection IDs, one for the recent transcript.
type Store interface {
	AddConnection(ctx context.Context, connID string) error
	RemoveConnection(ctx context.Context, connID string) error
	Connections(ctx context.Context) ([]string, error)
	AppendMessage(ctx context.Context, m chat.Message) error
	Recent(ctx context.Context, limit int) ([]chat.Message, error)
}

// Poster sends one frame to one connection. Implemented by the API Gateway
// management API client; faked in tests.
type Poster interface {
	Post(ctx context.Context, connID string, payload []byte) error
}

// Router implements the three WebSocket routes. NewID and NowMS are injected so
// the tests assert on exact values rather than on "some UUID, some timestamp".
type Router struct {
	Store  Store
	Poster Poster
	NewID  func() string
	NowMS  func() int64
	Log    *slog.Logger
}

// Connect registers the connection, and nothing more.
//
// API Gateway does not consider a connection to
// exist until the $connect integration has returned, so a PostToConnection
// issued from inside this handler -- to the connecting client itself, or a
// presence broadcast that happens to include it -- is answered 410 Gone. The
// 410 is indistinguishable from a genuinely dead peer, so the reaping logic
// then deletes the row that was just written and the registry stays empty:
// messages are stored but delivered to nobody, with no error anywhere.
//
// The transcript and the presence count are therefore sent in response to the
// client's hello frame instead. See Hello.
func (r *Router) Connect(ctx context.Context, connID string) error {
	if err := r.Store.AddConnection(ctx, connID); err != nil {
		return fmt.Errorf("register connection: %w", err)
	}
	return nil
}

// Hello completes the handshake: it sends the connection the transcript it
// missed and tells everyone the peer count changed.
//
// History goes out before the presence broadcast so a client is never told
// "2 windows connected" while its own message list is still empty.
func (r *Router) Hello(ctx context.Context, connID string) error {
	recent, err := r.Store.Recent(ctx, chat.HistoryLimit)
	if err != nil {
		// A failed history read is not a reason to drop the connection: the
		// client reconnects and rehydrates, and dropping would lose the socket
		// entirely. Log it and carry on with an empty transcript.
		r.logger().WarnContext(ctx, "history read failed", "conn", connID, "err", err)
		recent = nil
	}

	if err := r.send(ctx, connID, chat.Outbound{Type: chat.TypeHistory, Messages: recent}); err != nil &&
		!errors.Is(err, ErrGone) {
		return err
	}
	return r.broadcastPresence(ctx)
}

// Disconnect removes the connection. API Gateway invokes $disconnect on a
// best-effort basis only, and is not guaranteed for every close, so the
// connections table also carries a TTL as the backstop.
func (r *Router) Disconnect(ctx context.Context, connID string) error {
	if err := r.Store.RemoveConnection(ctx, connID); err != nil {
		return fmt.Errorf("remove connection: %w", err)
	}
	return r.broadcastPresence(ctx)
}

// Message handles one client frame. A validation failure is reported back to
// the sender and is not an invocation error: returning an error here would make
// Lambda retry a frame that will never become valid.
func (r *Router) Message(ctx context.Context, connID string, raw []byte) error {
	var in chat.Inbound
	if err := json.Unmarshal(raw, &in); err != nil {
		return r.sendError(ctx, connID, "malformed frame")
	}

	switch in.Type {
	case chat.TypeHello:
		return r.Hello(ctx, connID)

	case chat.TypePing:
		return r.send(ctx, connID, chat.Outbound{Type: chat.TypePong})

	case chat.TypeSend:
		author, body, err := in.Validate()
		if err != nil {
			return r.sendError(ctx, connID, err.Error())
		}
		msg := chat.Message{
			ID:       r.NewID(),
			Author:   author,
			Body:     body,
			SentAtMS: r.NowMS(),
			ClientID: in.ClientID,
		}
		if err := r.Store.AppendMessage(ctx, msg); err != nil {
			return fmt.Errorf("append message: %w", err)
		}
		return r.broadcast(ctx, chat.Outbound{Type: chat.TypeMessage, Message: &msg})

	default:
		return r.sendError(ctx, connID, "unknown frame type")
	}
}

func (r *Router) broadcastPresence(ctx context.Context) error {
	conns, err := r.Store.Connections(ctx)
	if err != nil {
		return fmt.Errorf("list connections: %w", err)
	}
	return r.fanOut(ctx, conns, chat.Outbound{Type: chat.TypePresence, Count: len(conns)})
}

func (r *Router) broadcast(ctx context.Context, frame chat.Outbound) error {
	conns, err := r.Store.Connections(ctx)
	if err != nil {
		return fmt.Errorf("list connections: %w", err)
	}
	return r.fanOut(ctx, conns, frame)
}

// fanOut posts to every connection and reaps the dead ones. One unreachable
// peer must not stop delivery to the rest, so failures are collected rather
// than returned on the first error.
func (r *Router) fanOut(ctx context.Context, conns []string, frame chat.Outbound) error {
	payload, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("marshal frame: %w", err)
	}

	var errs []error
	for _, id := range conns {
		switch err := r.Poster.Post(ctx, id, payload); {
		case err == nil:
		case errors.Is(err, ErrGone):
			if rmErr := r.Store.RemoveConnection(ctx, id); rmErr != nil {
				errs = append(errs, fmt.Errorf("reap %s: %w", id, rmErr))
			}
		default:
			errs = append(errs, fmt.Errorf("post to %s: %w", id, err))
		}
	}
	return errors.Join(errs...)
}

func (r *Router) send(ctx context.Context, connID string, frame chat.Outbound) error {
	payload, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("marshal frame: %w", err)
	}
	if err := r.Poster.Post(ctx, connID, payload); err != nil {
		if errors.Is(err, ErrGone) {
			return errors.Join(ErrGone, r.Store.RemoveConnection(ctx, connID))
		}
		return fmt.Errorf("post to %s: %w", connID, err)
	}
	return nil
}

func (r *Router) sendError(ctx context.Context, connID, reason string) error {
	err := r.send(ctx, connID, chat.Outbound{Type: chat.TypeError, Error: reason})
	if errors.Is(err, ErrGone) {
		return nil
	}
	return err
}

func (r *Router) logger() *slog.Logger {
	if r.Log != nil {
		return r.Log
	}
	return slog.Default()
}
