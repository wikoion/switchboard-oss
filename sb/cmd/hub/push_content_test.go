package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// openPushContent undoes sealPushContent, as the phone does.
func openPushContent(t *testing.T, key []byte, sealed string) pushContent {
	t.Helper()
	box, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(key)
	gcm, _ := cipher.NewGCM(block)
	plain, err := gcm.Open(nil, box[:gcm.NonceSize()], box[gcm.NonceSize():], nil)
	if err != nil {
		t.Fatalf("the sealed message doesn't open with the phone's key: %v", err)
	}
	var content pushContent
	if err := json.Unmarshal(plain, &content); err != nil {
		t.Fatal(err)
	}
	return content
}

func TestPushCarriesTheMessageSealedForThePhone(t *testing.T) {
	long := strings.Repeat("é", 4000)
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer as-token" || r.URL.Query().Get("user_id") != "@richard:switchboard.internal" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/_matrix/client/v3/rooms/!chat/state/m.room.create/":
			io.WriteString(w, `{"type":"m.room.create","origin_server_ts":1000}`)
		case "/_matrix/client/v3/rooms/!chat/event/$hello":
			io.WriteString(w, `{"type":"m.room.message","sender":"@whatsapp_1:switchboard.internal","origin_server_ts":5000000,
				"content":{"msgtype":"m.text","body":"See you at 7","formatted_body":"<b>See you at 7</b>","m.mentions":{}}}`)
		case "/_matrix/client/v3/rooms/!chat/event/$long":
			b, _ := json.Marshal(map[string]any{"type": "m.room.message", "sender": "@whatsapp_1:switchboard.internal",
				"origin_server_ts": 5000000, "content": map[string]any{"msgtype": "m.text", "body": long}})
			w.Write(b)
		case "/_matrix/client/v3/rooms/!chat/state/m.room.member/@whatsapp_1:switchboard.internal":
			io.WriteString(w, `{"membership":"join","displayname":"Alice","avatar_url":"mxc://switchboard.internal/alice"}`)
		case "/_matrix/client/v3/rooms/!chat/state/m.room.name":
			io.WriteString(w, `{"name":"Family"}`)
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

	key := []byte("0123456789abcdef0123456789abcdef")
	withKey := `{"app_id":"a","pushkey":"k1","data":{"format":"event_id_only","sb_key":"` + base64.StdEncoding.EncodeToString(key) +
		`","default_payload":{"aps":{"mutable-content":1}}}}`
	withoutKey := `{"app_id":"a","pushkey":"k2","data":{"format":"event_id_only","default_payload":{"aps":{"mutable-content":1}}}}`
	push := func(event, devices string) map[string]any {
		t.Helper()
		body := `{"notification":{"room_id":"!chat","event_id":"` + event + `","counts":{"unread":3},"devices":[` + devices + `]}}`
		resp, err := http.Post(hub.URL+"/_matrix/push/v1/notify", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		got := forwarded[len(forwarded)-1]
		if strings.Contains(got, "sb_key") || strings.Contains(got, base64.StdEncoding.EncodeToString(key)) {
			t.Fatalf("the phone's key was passed on to the gateway: %s", got)
		}
		var out map[string]any
		if err := json.Unmarshal([]byte(got), &out); err != nil {
			t.Fatal(err)
		}
		return out["notification"].(map[string]any)
	}
	payload := func(n map[string]any, device int) map[string]any {
		return n["devices"].([]any)[device].(map[string]any)["data"].(map[string]any)["default_payload"].(map[string]any)
	}

	n := push("$hello", withKey+","+withoutKey)
	if n["room_id"] != "!chat" || n["event_id"] != "$hello" || n["counts"].(map[string]any)["unread"] != float64(3) {
		t.Errorf("the rest of the push changed: %v", n)
	}
	if payload(n, 0)["aps"].(map[string]any)["mutable-content"] != float64(1) {
		t.Errorf("the payload's own fields changed: %v", payload(n, 0))
	}
	got := openPushContent(t, key, payload(n, 0)["sb"].(string))
	if got.Event.Type != "m.room.message" || got.Event.Sender != "@whatsapp_1:switchboard.internal" || got.Event.TS != 5000000 {
		t.Errorf("event = %+v", got.Event)
	}
	if got.Event.Content["body"] != "See you at 7" || got.Event.Content["msgtype"] != "m.text" || len(got.Event.Content) != 2 {
		t.Errorf("content = %v, want only the type and the text", got.Event.Content)
	}
	if got.Member == nil || got.Member.DisplayName != "Alice" || got.Member.AvatarURL != "mxc://switchboard.internal/alice" {
		t.Errorf("member = %+v", got.Member)
	}
	if got.RoomName != "Family" {
		t.Errorf("room name = %q", got.RoomName)
	}
	if _, sealed := payload(n, 1)["sb"]; sealed {
		t.Error("a device that gave no key was sent a sealed message")
	}

	// A long message is cut to fit a push, on a whole character.
	n = push("$long", withKey)
	sealed := payload(n, 0)["sb"].(string)
	if len(sealed) > 2600 {
		t.Errorf("the sealed message is %d bytes, too big for a push", len(sealed))
	}
	body := openPushContent(t, key, sealed).Event.Content["body"].(string)
	if !strings.HasPrefix(body, "ééé") || !strings.HasSuffix(body, "é…") || len(body) > maxPushText+3 {
		t.Errorf("long text cut to %d bytes ending %q", len(body), body[len(body)-6:])
	}

	// A message that can't be read goes on as a plain push.
	n = push("$missing", withKey)
	if _, sealed := payload(n, 0)["sb"]; sealed {
		t.Error("a sealed message for an event that couldn't be read")
	}
}
