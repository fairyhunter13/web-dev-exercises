// Command localserver runs the chat backend as a plain WebSocket server, so the
// whole application can be reviewed with `go run` and `npm run dev` and no AWS
// account at all. The AWS Lambda build in ../lambda shares the protocol and the
// fan-out logic with this one; only the transport differs.
//
//	go run ./cmd/localserver          # listens on :8080, ws://localhost:8080/ws
//	PORT=9000 go run ./cmd/localserver
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/chat"
)

// connSink adapts a WebSocket connection to chat.Sink.
//
// The mutex is not optional. A WebSocket connection allows exactly one
// concurrent writer, and here the broadcast triggered by any other client can
// write to this connection at any time. Without the lock, two simultaneous
// broadcasts interleave frames and corrupt the stream.
type connSink struct {
	id   string
	conn *websocket.Conn
	mu   sync.Mutex
}

func (c *connSink) ID() string { return c.id }

func (c *connSink) Send(out chat.Outbound) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// A per-write deadline, so one client with a full TCP receive buffer
	// cannot block a broadcast indefinitely. On timeout the write fails, the
	// hub evicts the client, and everyone else carries on.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return wsjson.Write(ctx, c.conn, out)
}

type server struct {
	hub     *chat.Hub
	origins []string
	log     *slog.Logger
}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	addr := ":" + envOr("PORT", "8080")

	// Origins are allow-listed rather than checked off. An unchecked origin on
	// a WebSocket is cross-site request forgery with a persistent channel
	// attached: any page can open a socket to this server as the user.
	origins := []string{"localhost:5173", "127.0.0.1:5173", "localhost:4173"}
	if extra := os.Getenv("ALLOWED_ORIGIN"); extra != "" {
		origins = append(origins, extra)
	}

	srv := &server{hub: chat.NewHub(), origins: origins, log: log}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", srv.handleWS)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown, so Ctrl-C closes sockets cleanly and the browser sees
	// a normal close rather than a reset, which is also how the client's
	// reconnect path gets exercised during development.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Info("chat server listening", "addr", addr, "ws", "ws://localhost"+addr+"/ws")
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
}

func newID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
