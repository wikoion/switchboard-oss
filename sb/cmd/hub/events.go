package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// hubEvent is one message on the /events stream.
type hubEvent struct {
	Type   string      `json:"type"`
	Bridge string      `json:"bridge,omitempty"`
	State  bridgeState `json:"state"`
}

// broker fans events out to every connected app. A subscriber that falls
// behind loses events rather than holding up the bridges; the app refetches
// /bridges on reconnect, so nothing is lost for good.
type broker struct {
	mu   sync.Mutex
	subs map[chan hubEvent]struct{}
}

func newBroker() *broker { return &broker{subs: map[chan hubEvent]struct{}{}} }

func (b *broker) subscribe() chan hubEvent {
	ch := make(chan hubEvent, 16)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *broker) unsubscribe(ch chan hubEvent) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
}

func (b *broker) publish(e hubEvent) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs {
		select {
		case ch <- e:
		default:
		}
	}
}

// keepAlive is how often an idle stream sends a comment, so proxies and
// the phone's network don't drop it.
var keepAlive = 25 * time.Second

// events streams bridge-state changes as server-sent events.
func (s *server) events(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "M_UNKNOWN", "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	ch := s.broker.subscribe()
	defer s.broker.unsubscribe(ch)

	fmt.Fprint(w, ": connected\n\n")
	flusher.Flush()
	tick := time.NewTicker(keepAlive)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-tick.C:
			fmt.Fprint(w, ": keep-alive\n\n")
			flusher.Flush()
		case e := <-ch:
			data, err := json.Marshal(e)
			if err != nil {
				continue
			}
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.Type, data)
			flusher.Flush()
		}
	}
}
