package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestPushHoldsBackImportedHistory(t *testing.T) {
	created := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	sent := map[string]time.Time{
		"$old":   created.Add(-48 * time.Hour),  // imported when the chat was made
		"$first": created.Add(-3 * time.Second), // the message that made the chat
		"$later": created.Add(5 * time.Hour),    // anything since
	}
	var createFetches atomic.Int32
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer as-token" || r.URL.Query().Get("user_id") != "@richard:switchboard.internal" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch {
		case r.URL.Path == "/_matrix/client/v3/rooms/!chat/state/m.room.create/" && r.URL.Query().Get("format") == "event":
			createFetches.Add(1)
			io.WriteString(w, `{"type":"m.room.create","origin_server_ts":`+itoa(created.UnixMilli())+`}`)
		case strings.HasPrefix(r.URL.Path, "/_matrix/client/v3/rooms/!chat/event/"):
			ts, ok := sent[strings.TrimPrefix(r.URL.Path, "/_matrix/client/v3/rooms/!chat/event/")]
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			io.WriteString(w, `{"type":"m.room.message","origin_server_ts":`+itoa(ts.UnixMilli())+`}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(hs.Close)
	var forwarded []string
	sygnal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		forwarded = append(forwarded, string(b))
		io.WriteString(w, `{"rejected":[]}`)
	}))
	t.Cleanup(sygnal.Close)
	srv := newServer(config{
		Owner:      "@richard:switchboard.internal",
		Homeserver: hs.URL,
		Push:       &pushConfig{Gateway: sygnal.URL, ASToken: "as-token"},
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	hub := httptest.NewServer(srv.routes())
	t.Cleanup(hub.Close)

	push := func(body string) {
		t.Helper()
		resp, err := http.Post(hub.URL+"/_matrix/push/v1/notify", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `"rejected":[]`) {
			t.Fatalf("push %s: HTTP %d %s", body, resp.StatusCode, b)
		}
	}
	for _, ev := range []string{"$old", "$first", "$later", "$missing"} {
		push(`{"notification":{"room_id":"!chat","event_id":"` + ev + `","devices":[]}}`)
	}
	push(`{"notification":{"counts":{"unread":2},"devices":[]}}`) // badge only

	want := []string{"$first", "$later", "$missing", `"unread":2`}
	if len(forwarded) != len(want) {
		t.Fatalf("forwarded %d pushes, want %d: %v", len(forwarded), len(want), forwarded)
	}
	for i, w := range want {
		if !strings.Contains(forwarded[i], w) {
			t.Errorf("push %d: got %s, want one containing %s", i, forwarded[i], w)
		}
	}
	if n := createFetches.Load(); n != 1 {
		t.Errorf("fetched the room's creation %d times, want once", n)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func TestPushTurnsOffInviteNotifications(t *testing.T) {
	var calls atomic.Int32
	done := make(chan string, 1)
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusBadGateway) // Synapse still starting
			return
		}
		b, _ := io.ReadAll(r.Body)
		io.WriteString(w, `{}`)
		done <- r.Method + " " + r.URL.Path + "?" + r.URL.RawQuery + " " + r.Header.Get("Authorization") + " " + string(b)
	}))
	t.Cleanup(hs.Close)
	p := &pushFilter{homeserver: hs.URL, asToken: "as-token", owner: "@richard:switchboard.internal", http: hs.Client()}
	go p.muteInvites(t.Context(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	select {
	case got := <-done:
		want := "PUT /_matrix/client/v3/pushrules/global/override/.m.rule.invite_for_me/enabled?user_id=%40richard%3Aswitchboard.internal Bearer as-token {\"enabled\":false}"
		if got != want {
			t.Errorf("got  %s\nwant %s", got, want)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("never turned off invite notifications")
	}
}
