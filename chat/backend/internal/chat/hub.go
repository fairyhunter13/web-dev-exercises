package chat

import (
	"sync"
)

// Sink is anything a broadcast can be written to. The local server implements
// it with a WebSocket connection; a test implements it with a slice. That is
// what lets the fan-out logic be tested without a network.
type Sink interface {
	Send(Outbound) error
	ID() string
}

// Hub owns the set of connected clients and the recent-message ring buffer.
//
// A mutex, not a channel-and-select goroutine. The state is small, every
// operation is short, and the only requirement is one writer at a time. A hub
// goroutine would add a lifecycle to manage and a channel to size. That trade
// flips if broadcasts get slow enough to hold the lock across a network write,
// which is why Broadcast copies the sink list and releases the lock before
// writing.
type Hub struct {
	mu      sync.RWMutex
	clients map[string]Sink
	recent  []Message
	// GoneFunc, when set, is called for a sink whose Send failed, so the
	// caller can clean up. On API Gateway this is the GoneException path.
	GoneFunc func(id string)
}

func NewHub() *Hub {
	return &Hub{clients: make(map[string]Sink)}
}

// Join registers a client and returns the history it should be sent.
func (h *Hub) Join(s Sink) []Message {
	h.mu.Lock()
	h.clients[s.ID()] = s
	history := append([]Message(nil), h.recent...)
	h.mu.Unlock()
	return history
}

// Leave removes a client. Safe to call for an id that is not present, because
// a disconnect can be observed from more than one place.
func (h *Hub) Leave(id string) {
	h.mu.Lock()
	delete(h.clients, id)
	h.mu.Unlock()
}

func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

// Recent returns a copy of the ring buffer.
func (h *Hub) Recent() []Message {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return append([]Message(nil), h.recent...)
}

// Record appends a message to the recent buffer, trimming to HistoryLimit.
func (h *Hub) Record(m Message) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.recent = append(h.recent, m)
	if len(h.recent) > HistoryLimit {
		// Reslice from the tail rather than shifting in place, so the buffer
		// stays bounded without copying on every message.
		h.recent = append([]Message(nil), h.recent[len(h.recent)-HistoryLimit:]...)
	}
}

// Broadcast sends a frame to every connected client and returns the ids of the
// clients whose send failed. Those are dropped from the hub: a peer that
// cannot be written to is gone, and keeping it leaks a map entry per dead
// connection.
//
// The snapshot-then-write shape is intentional. Holding the lock across a
// network write would let one slow client stall every other client's messages.
func (h *Hub) Broadcast(out Outbound) []string {
	h.mu.RLock()
	sinks := make([]Sink, 0, len(h.clients))
	for _, s := range h.clients {
		sinks = append(sinks, s)
	}
	h.mu.RUnlock()

	var failed []string
	for _, s := range sinks {
		if err := s.Send(out); err != nil {
			failed = append(failed, s.ID())
		}
	}

	for _, id := range failed {
		h.Leave(id)
		if h.GoneFunc != nil {
			h.GoneFunc(id)
		}
	}
	return failed
}

// BroadcastPresence tells everyone how many clients are connected. Sent after
// a join or a leave so the two demo windows can each see the other arrive.
func (h *Hub) BroadcastPresence() {
	h.Broadcast(Outbound{Type: TypePresence, Count: h.Count()})
}
