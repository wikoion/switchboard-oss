package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
	"unicode/utf8"
)

// The phone's notification extension can only show a message it has: the
// push names the room and the event, and the extension fetches the rest
// over the tailnet, which it often can't reach in the seconds iOS gives
// it. So the hub sends the message along, sealed with a key that only the
// phone and this server hold. Apple and Sygnal carry it without being able
// to read it.
//
// The app makes the key, keeps it in its keychain and gives it to the
// server as `sb_key` in its pusher's data, which Synapse hands the hub with
// each push. The hub takes the key out before passing the push on, and
// puts the sealed message into the payload for APNs as `sb`: base64 of
// AES-256-GCM's nonce, ciphertext and tag.

const (
	pushKeyField     = "sb_key"
	pushContentField = "sb"
	// APNs takes 4096 bytes, and Sygnal sends what it is given. These keep
	// the sealed message near 2 KB at most.
	maxPushText = 600
	maxPushName = 120
	// How long fetching the message may hold a push up.
	pushContentTimeout = 3 * time.Second
)

// pushContent is what the extension draws a notification from: the same
// three things it would otherwise fetch.
type pushContent struct {
	Event    pushEvent   `json:"event"`
	Member   *pushMember `json:"member,omitempty"`
	RoomName string      `json:"room_name,omitempty"`
}

type pushEvent struct {
	Type    string         `json:"type"`
	Sender  string         `json:"sender"`
	TS      int64          `json:"origin_server_ts"`
	Content map[string]any `json:"content"`
}

type pushMember struct {
	DisplayName string `json:"displayname,omitempty"`
	AvatarURL   string `json:"avatar_url,omitempty"`
}

// withContent returns the push with the message sealed into it for each
// device that gave a key, and with the keys taken out. A push it can't add
// to goes on as it came, less the keys: the extension then fetches the
// message as before.
func (p *pushFilter) withContent(ctx context.Context, body []byte, log interface{ Warn(string, ...any) }) []byte {
	var push map[string]any
	if json.Unmarshal(body, &push) != nil {
		return body
	}
	n, _ := push["notification"].(map[string]any)
	devices, _ := n["devices"].([]any)
	keys := map[int][]byte{}
	changed := false
	for i, d := range devices {
		device, _ := d.(map[string]any)
		data, _ := device["data"].(map[string]any)
		encoded, ok := data[pushKeyField].(string)
		if !ok {
			continue
		}
		delete(data, pushKeyField)
		changed = true
		if key, err := base64.StdEncoding.DecodeString(encoded); err == nil && len(key) == 32 {
			keys[i] = key
		}
	}
	if !changed {
		return body
	}
	roomID, _ := n["room_id"].(string)
	eventID, _ := n["event_id"].(string)
	if len(keys) > 0 && roomID != "" && eventID != "" {
		ctx, cancel := context.WithTimeout(ctx, pushContentTimeout)
		defer cancel()
		content, err := p.content(ctx, roomID, eventID)
		if err != nil {
			log.Warn("push: couldn't read the message to send along", "room", roomID, "event", eventID, "err", err)
		} else if plain, err := json.Marshal(content); err == nil {
			for i, key := range keys {
				sealed, err := sealPushContent(key, plain)
				if err != nil {
					continue
				}
				data := devices[i].(map[string]any)["data"].(map[string]any)
				payload, _ := data["default_payload"].(map[string]any)
				if payload == nil {
					payload = map[string]any{}
					data["default_payload"] = payload
				}
				payload[pushContentField] = sealed
			}
		}
	}
	out, err := json.Marshal(push)
	if err != nil {
		return body
	}
	return out
}

// sealPushContent encrypts for the phone: base64 of nonce, ciphertext and
// tag, which is CryptoKit's "combined" form of an AES-GCM box.
func sealPushContent(key, plain []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(gcm.Seal(nonce, nonce, plain, nil)), nil
}

// content reads the message, its sender's name and picture in the chat,
// and the chat's name, as the owner.
func (p *pushFilter) content(ctx context.Context, roomID, eventID string) (*pushContent, error) {
	room := "/rooms/" + url.PathEscape(roomID)
	var event struct {
		Type    string         `json:"type"`
		Sender  string         `json:"sender"`
		TS      int64          `json:"origin_server_ts"`
		Content map[string]any `json:"content"`
	}
	if err := p.get(ctx, room+"/event/"+url.PathEscape(eventID), &event); err != nil {
		return nil, err
	}
	if event.Sender == "" {
		return nil, fmt.Errorf("event %s has no sender", eventID)
	}
	out := &pushContent{Event: pushEvent{
		Type:    event.Type,
		Sender:  event.Sender,
		TS:      event.TS,
		Content: trimPushContent(event.Content),
	}}
	// Without these the notification still has the text.
	var member pushMember
	if p.get(ctx, room+"/state/m.room.member/"+url.PathEscape(event.Sender), &member) == nil {
		member.DisplayName = truncate(member.DisplayName, maxPushName)
		if len(member.AvatarURL) > 2*maxPushName {
			member.AvatarURL = ""
		}
		out.Member = &member
	}
	var name struct {
		Name string `json:"name"`
	}
	if p.get(ctx, room+"/state/m.room.name", &name) == nil {
		out.RoomName = truncate(name.Name, maxPushName)
	}
	return out, nil
}

// trimPushContent keeps the parts of a message's content a notification is
// worded from, cut to fit a push.
func trimPushContent(content map[string]any) map[string]any {
	out := map[string]any{}
	if s, ok := content["msgtype"].(string); ok {
		out["msgtype"] = truncate(s, maxPushName)
	}
	if s, ok := content["body"].(string); ok {
		out["body"] = truncate(s, maxPushText)
	}
	if s, ok := content["filename"].(string); ok {
		out["filename"] = truncate(s, maxPushName)
	}
	if rel, ok := content["m.relates_to"].(map[string]any); ok {
		if key, ok := rel["key"].(string); ok {
			out["m.relates_to"] = map[string]any{"key": truncate(key, maxPushName)}
		}
	}
	if _, ok := content["org.matrix.msc3245.voice"]; ok {
		out["org.matrix.msc3245.voice"] = map[string]any{}
	}
	return out
}

// truncate cuts s to at most max bytes without splitting a character,
// marking the cut.
func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

// get fetches a client-API resource as the owner into v.
func (p *pushFilter) get(ctx context.Context, path string, v any) error {
	req, err := p.request(ctx, http.MethodGet, path, nil)
	if err != nil {
		return err
	}
	resp, err := p.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(v)
}
