// Package chat holds the wire protocol and the in-memory hub shared by the two
// deployment targets: the local WebSocket server (cmd/localserver) and the AWS
// Lambda handlers (cmd/lambda). Keeping the protocol in one place is what stops
// the two from drifting.
package chat

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// Frame types. Both directions use a "type" discriminator so the client can
// switch on a single field; the TypeScript side models this as a discriminated
// union with the same string literals.
const (
	// Client -> server.
	TypeSend = "send"
	TypePing = "ping"
	// TypeHello is the client's "I am ready" frame, sent once the socket
	// opens. It exists because of a hard API Gateway rule: a connection does
	// not exist as far as the @connections management API is concerned until
	// the $connect handler has returned, so anything the server posts to the
	// connecting client from inside $connect comes back 410 Gone. The server
	// therefore only registers the connection in $connect and waits to be
	// asked for the transcript. The local server follows the same handshake so
	// the two transports cannot drift.
	TypeHello = "hello"

	// Server -> client.
	TypeMessage  = "message"  // a chat message, broadcast to everyone
	TypeHistory  = "history"  // recent messages, sent once on connect
	TypePresence = "presence" // connected-client count changed
	TypePong     = "pong"
	TypeError    = "error"
)

// Limits. API Gateway closes a WebSocket connection with code 1009 if a frame
// exceeds 32 KB, so the body cap sits well under that. A rejected message with
// a readable error is easier to debug than a dropped connection.
const (
	MaxBodyRunes   = 2000
	MaxAuthorRunes = 40
	// HistoryLimit is how many past messages a reconnecting client is sent.
	// Reconnection is not optional on API Gateway: the idle timeout is 10
	// minutes and the hard connection cap is 2 hours, so any long-lived
	// client will be disconnected and must rehydrate.
	HistoryLimit = 50
)

var (
	ErrEmptyBody   = errors.New("message body is empty")
	ErrBodyTooLong = errors.New("message body is too long")
	ErrNoAuthor    = errors.New("author is required")
)

// Inbound is a frame received from a client.
type Inbound struct {
	Type   string `json:"type"`
	Author string `json:"author,omitempty"`
	Body   string `json:"body,omitempty"`
	// ClientID lets the sender recognise its own message in the broadcast and
	// reconcile the optimistic copy it already rendered.
	ClientID string `json:"clientId,omitempty"`
}

// Outbound is a frame sent to a client. Only the fields relevant to Type are
// populated; the rest are omitted so the wire format stays small.
type Outbound struct {
	Type     string    `json:"type"`
	Message  *Message  `json:"message,omitempty"`
	Messages []Message `json:"messages,omitempty"`
	Count    int       `json:"count,omitempty"`
	Error    string    `json:"error,omitempty"`
}

// Message is a stored chat message.
type Message struct {
	ID       string `json:"id"`
	Author   string `json:"author"`
	Body     string `json:"body"`
	SentAtMS int64  `json:"sentAtMs"`
	ClientID string `json:"clientId,omitempty"`
}

// Validate checks an inbound send frame and returns the cleaned author and
// body. Validation lives server-side because a client is not a trust boundary:
// the browser's maxlength attribute is a hint to the user, not a constraint on
// the protocol.
//
// Length is counted in runes, not bytes. A cap expressed in bytes silently
// gives a user writing in Indonesian or Japanese a shorter message than a user
// writing in English.
func (in Inbound) Validate() (author, body string, err error) {
	author = strings.TrimSpace(in.Author)
	body = strings.TrimSpace(in.Body)

	if author == "" {
		return "", "", ErrNoAuthor
	}
	if utf8.RuneCountInString(author) > MaxAuthorRunes {
		author = truncateRunes(author, MaxAuthorRunes)
	}
	if body == "" {
		return "", "", ErrEmptyBody
	}
	if utf8.RuneCountInString(body) > MaxBodyRunes {
		return "", "", ErrBodyTooLong
	}
	return author, body, nil
}

func truncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
