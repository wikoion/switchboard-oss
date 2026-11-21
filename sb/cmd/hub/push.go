package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// historySlack is how long before its chat was created a message can have
// been sent and still count as new. A bridge creates a chat when its first
// message arrives, a second or two after it was sent; the history it
// imports into a chat it has just created is older.
const historySlack = 2 * time.Minute

// pushFilter stands between Synapse and Sygnal. When you link a network,
// the bridge imports each chat's history as ordinary messages, and Synapse
// would push every one; the filter drops pushes for messages sent before
// their chat came to this server, and passes everything else on.
type pushFilter struct {
	gateway    string // Sygnal's notify URL
	homeserver string
	asToken    string // the double-puppet appservice, to read as the owner
	owner      string
	http       *http.Client

	mu      sync.Mutex
	created map[string]time.Time // room ID to when the room was created
}

type pushRequest struct {
	Notification struct {
		EventID string `json:"event_id"`
		RoomID  string `json:"room_id"`
	} `json:"notification"`
}

func (s *server) notify(w http.ResponseWriter, r *http.Request) {
	p := s.push
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "M_BAD_JSON", "unreadable body")
		return
	}
	var req pushRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "M_BAD_JSON", "invalid JSON")
		return
	}
	if n := req.Notification; n.EventID != "" && n.RoomID != "" {
		old, err := p.isHistory(r.Context(), n.RoomID, n.EventID)
		if err != nil {
			// Better a push too many than a message missed.
			s.log.Warn("push: couldn't date the message, pushing", "room", n.RoomID, "event", n.EventID, "err", err)
		} else if old {
			s.log.Info("push: imported history, not pushed", "room", n.RoomID, "event", n.EventID)
			writeJSON(w, http.StatusOK, map[string][]string{"rejected": {}})
			return
		}
	}
	body = p.withContent(r.Context(), body, s.log)
	fwd, err := http.NewRequestWithContext(r.Context(), http.MethodPost, p.gateway, bytes.NewReader(body))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "M_UNKNOWN", err.Error())
		return
	}
	fwd.Header.Set("Content-Type", "application/json")
	resp, err := p.http.Do(fwd)
	if err != nil {
		writeError(w, http.StatusBadGateway, "M_UNKNOWN", "push gateway unreachable")
		return
	}
	defer resp.Body.Close()
	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// muteInvites turns off the owner's push rule for invites. Bridges invite
// you to every chat they create and accept for you straight away, so each
// invite would only be a notification nobody can read: the phone can't
// fetch an event from a chat you haven't joined, and linking a network
// creates dozens. Runs until it succeeds, since Synapse may still be
// starting.
func (p *pushFilter) muteInvites(ctx context.Context, log interface{ Warn(string, ...any) }) {
	for {
		err := p.call(ctx, http.MethodPut, "/pushrules/global/override/.m.rule.invite_for_me/enabled", `{"enabled":false}`)
		if err == nil {
			return
		}
		log.Warn("push: couldn't turn off invite notifications, retrying", "err", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
}

// call makes a client-API request as the owner and discards the reply.
func (p *pushFilter) call(ctx context.Context, method, path, body string) error {
	req, err := p.request(ctx, method, path, strings.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%s %s: HTTP %d %s", method, path, resp.StatusCode, b)
	}
	return nil
}

// request builds a client-API request made as the owner through the
// double-puppet appservice.
func (p *pushFilter) request(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	u, err := url.Parse(p.homeserver + "/_matrix/client/v3" + path)
	if err != nil {
		return nil, err
	}
	q := u.Query()
	q.Set("user_id", p.owner)
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.asToken)
	return req, nil
}

// isHistory reports whether the event was sent well before its room was
// created, which only happens when a bridge imports old messages.
func (p *pushFilter) isHistory(ctx context.Context, roomID, eventID string) (bool, error) {
	created, err := p.roomCreated(ctx, roomID)
	if err != nil {
		return false, err
	}
	sent, err := p.timestamp(ctx, "/rooms/"+url.PathEscape(roomID)+"/event/"+url.PathEscape(eventID))
	if err != nil {
		return false, err
	}
	return sent.Before(created.Add(-historySlack)), nil
}

func (p *pushFilter) roomCreated(ctx context.Context, roomID string) (time.Time, error) {
	p.mu.Lock()
	t, ok := p.created[roomID]
	p.mu.Unlock()
	if ok {
		return t, nil
	}
	t, err := p.timestamp(ctx, "/rooms/"+url.PathEscape(roomID)+"/state/m.room.create/?format=event")
	if err != nil {
		return time.Time{}, err
	}
	p.mu.Lock()
	p.created[roomID] = t
	p.mu.Unlock()
	return t, nil
}

// timestamp fetches a client-API event, read as the owner, and returns its
// origin_server_ts.
func (p *pushFilter) timestamp(ctx context.Context, path string) (time.Time, error) {
	req, err := p.request(ctx, http.MethodGet, path, nil)
	if err != nil {
		return time.Time{}, err
	}
	resp, err := p.http.Do(req)
	if err != nil {
		return time.Time{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return time.Time{}, fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
	}
	var ev struct {
		TS int64 `json:"origin_server_ts"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ev); err != nil {
		return time.Time{}, err
	}
	if ev.TS == 0 {
		return time.Time{}, fmt.Errorf("%s: no origin_server_ts", path)
	}
	return time.UnixMilli(ev.TS), nil
}
