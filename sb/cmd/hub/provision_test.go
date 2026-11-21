package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The app's channel settings reach the bridges' switchboard/v1/channels
// endpoints through the same proxy as the login flow: every method, the
// path and query kept, the owner named in user_id.
func TestProvisionProxiesChannelSelection(t *testing.T) {
	hs := fakeHomeserver(t)
	var got []string
	bridge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery+" "+r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodDelete {
			w.WriteHeader(http.StatusConflict)
			io.WriteString(w, `{"errcode":"SWITCHBOARD_EVERY_CHANNEL_BRIDGED","error":"no"}`)
			return
		}
		io.WriteString(w, `{"selected":true}`)
	}))
	t.Cleanup(bridge.Close)
	srv := newServer(config{
		Owner:      "@richard:switchboard.internal",
		Homeserver: hs.URL,
		Bridges:    []bridgeConfig{{ID: "slack", Network: "Slack", Kind: "bridgev2", URL: bridge.URL}},
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	hub := httptest.NewServer(srv.routes())
	t.Cleanup(hub.Close)

	call := func(method, path, token string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(method, hub.URL+"/_switchboard/v1/bridges/"+path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(body)
	}

	if status, _ := call(http.MethodGet, "slack/provision/switchboard/v1/channels?login_id=T1-U1", "owner-token"); status != http.StatusOK {
		t.Errorf("list: HTTP %d", status)
	}
	if status, body := call(http.MethodPut, "slack/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1", "owner-token"); status != http.StatusOK || body != `{"selected":true}` {
		t.Errorf("select: HTTP %d %s", status, body)
	}
	// A bridge's refusal reaches the app as it was sent.
	if status, body := call(http.MethodDelete, "slack/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1", "owner-token"); status != http.StatusConflict || body != `{"errcode":"SWITCHBOARD_EVERY_CHANNEL_BRIDGED","error":"no"}` {
		t.Errorf("deselect: HTTP %d %s", status, body)
	}
	const owner = "user_id=%40richard%3Aswitchboard.internal Bearer owner-token"
	want := []string{
		"GET /_matrix/provision/switchboard/v1/channels?login_id=T1-U1&" + owner,
		"PUT /_matrix/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1&" + owner,
		"DELETE /_matrix/provision/switchboard/v1/channels/T1/C1?login_id=T1-U1&" + owner,
	}
	if len(got) != len(want) {
		t.Fatalf("bridge saw %q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("request %d: got %q, want %q", i, got[i], want[i])
		}
	}

	// Nobody but the owner gets through, and only to bridges that exist.
	if status, _ := call(http.MethodPut, "slack/provision/switchboard/v1/channels/T1/C1", "someone-else"); status != http.StatusUnauthorized {
		t.Errorf("another user's token: HTTP %d", status)
	}
	if status, _ := call(http.MethodPut, "discord/provision/switchboard/v1/channels/g/c", "owner-token"); status != http.StatusNotFound {
		t.Errorf("unknown bridge: HTTP %d", status)
	}
	if len(got) != len(want) {
		t.Errorf("refused requests must not reach the bridge: %q", got[len(want):])
	}
}
