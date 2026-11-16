package main

import (
	"bufio"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A homeserver that knows one token, the owner's.
func fakeHomeserver(t *testing.T) *httptest.Server {
	t.Helper()
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer owner-token" {
			w.WriteHeader(http.StatusUnauthorized)
			io.WriteString(w, `{"errcode":"M_UNKNOWN_TOKEN"}`)
			return
		}
		io.WriteString(w, `{"user_id":"@richard:switchboard.internal"}`)
	}))
	t.Cleanup(hs.Close)
	return hs
}

func TestEventsStreamBridgeStateChanges(t *testing.T) {
	hs := fakeHomeserver(t)
	srv := newServer(config{
		Owner:      "@richard:switchboard.internal",
		Homeserver: hs.URL,
		Bridges:    []bridgeConfig{{ID: "whatsapp", Network: "WhatsApp", Kind: "bridgev2", URL: "http://unused"}},
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	hub := httptest.NewServer(srv.routes())
	t.Cleanup(hub.Close)

	// Other users are turned away.
	resp, err := http.Get(hub.URL + "/_switchboard/v1/events")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no token: got %d", resp.StatusCode)
	}

	req, _ := http.NewRequest(http.MethodGet, hub.URL+"/_switchboard/v1/events", nil)
	req.Header.Set("Authorization", "Bearer owner-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type %q", ct)
	}
	lines := bufio.NewReader(resp.Body)
	if l, _ := lines.ReadString('\n'); !strings.HasPrefix(l, ": connected") {
		t.Fatalf("first line %q", l)
	}

	post := func(state string) {
		body := `{"state_event":"` + state + `","remote_id":"447700900123","remote_name":"Richard"}`
		r, err := http.Post(hub.URL+"/internal/bridge-state/whatsapp", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
	}
	post("CONNECTED")
	post("CONNECTED") // unchanged: not sent again
	post("BAD_CREDENTIALS")

	got := []string{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for len(got) < 2 {
			l, err := lines.ReadString('\n')
			if err != nil {
				return
			}
			if strings.HasPrefix(l, "data: ") {
				got = append(got, l)
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out; got %v", got)
	}
	if !strings.Contains(got[0], `"state_event":"CONNECTED"`) || !strings.Contains(got[0], `"bridge":"whatsapp"`) {
		t.Errorf("first event %s", got[0])
	}
	if !strings.Contains(got[1], `"state_event":"BAD_CREDENTIALS"`) {
		t.Errorf("second event %s", got[1])
	}
}
