package main

import (
	"context"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

func (s *server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: s.origins})
	if err != nil {
		s.log.Warn("accept failed", "err", err)
		return
	}
	// CloseNow is the correct deferred cleanup: a no-op if the handler already
	// closed cleanly, and it releases the connection if it did not.
	defer conn.CloseNow()

	sink := &connSink{id: newID(), conn: conn}
	s.hub.Join(sink)
	s.log.Info("client joined", "id", sink.id, "clients", s.hub.Count())

	defer func() {
		s.hub.Leave(sink.id)
		s.hub.BroadcastPresence()
		s.log.Info("client left", "id", sink.id, "clients", s.hub.Count())
	}()

	// The transcript is sent in reply to the client's hello frame, not here.
	// This server could send it immediately, but API Gateway cannot -- see
	// chat.TypeHello -- and a handshake that differs between the two
	// transports is a bug waiting for whichever one is tested less.
	s.readLoop(r.Context(), conn, sink)
}

func (s *server) readLoop(ctx context.Context, conn *websocket.Conn, sink *connSink) {
	// A read deadline longer than the client's heartbeat interval. If a client
	// stops sending anything at all: a laptop that slept, or a dropped network
	// with no FIN. The read fails and the connection is reaped instead of
	// leaking a goroutine and a hub entry.
	const idleTimeout = 90 * time.Second

	for {
		readCtx, cancel := context.WithTimeout(ctx, idleTimeout)
		var in chat.Inbound
		err := wsjson.Read(readCtx, conn, &in)
		cancel()
		if err != nil {
			return // client gone, or sent something that is not JSON
		}

		switch in.Type {
		case chat.TypeHello:
			// History first, so a reconnecting client rehydrates before it
			// sees any live message and the transcript stays in order.
			if err := sink.Send(chat.Outbound{Type: chat.TypeHistory, Messages: s.hub.Recent()}); err != nil {
				return
			}
			s.hub.BroadcastPresence()

		case chat.TypePing:
			// Application-level heartbeat. Browsers cannot send protocol ping
			// frames from JavaScript, so keep-alive has to live in the
			// protocol rather than in the WebSocket layer.
			_ = sink.Send(chat.Outbound{Type: chat.TypePong})

		case chat.TypeSend:
			author, body, err := in.Validate()
			if err != nil {
				_ = sink.Send(chat.Outbound{Type: chat.TypeError, Error: err.Error()})
				continue
			}
			msg := chat.Message{
				ID:       newID(),
				Author:   author,
				Body:     body,
				SentAtMS: time.Now().UnixMilli(),
				ClientID: in.ClientID,
			}
			s.hub.Record(msg)
			s.hub.Broadcast(chat.Outbound{Type: chat.TypeMessage, Message: &msg})

		default:
			_ = sink.Send(chat.Outbound{Type: chat.TypeError, Error: "unknown frame type"})
		}
	}
}
