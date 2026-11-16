package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"

	"switchboard/sb/internal/stack"
)

// localURL is Caddy's loopback port, so the test takes the same path through
// Caddy that devices take, minus Tailscale.
const localURL = "http://127.0.0.1:8080"

type client struct {
	base, token string
	http        *http.Client
}

func (c *client) do(method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s: HTTP %d: %s", method, path, resp.StatusCode, strings.TrimSpace(string(data)))
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}

type checker struct{ failed int }

func (k *checker) check(name string, err error) bool {
	if err != nil {
		k.failed++
		fmt.Printf("  FAIL  %s: %v\n", name, err)
		return false
	}
	fmt.Printf("  ok    %s\n", name)
	return true
}

func smokeTest(s *stack.Stack) error {
	k := &checker{}
	hc := &http.Client{Timeout: 40 * time.Second}
	c := &client{base: localURL, http: hc}

	var wk struct {
		Homeserver struct {
			BaseURL string `json:"base_url"`
		} `json:"m.homeserver"`
	}
	k.check("well-known points at "+s.Settings.PublicURL, func() error {
		if err := c.do("GET", "/.well-known/matrix/client", nil, &wk); err != nil {
			return err
		}
		if wk.Homeserver.BaseURL != strings.TrimRight(s.Settings.PublicURL, "/") {
			return fmt.Errorf("got %q", wk.Homeserver.BaseURL)
		}
		return nil
	}())
	k.check("admin API blocked at the proxy", func() error {
		err := c.do("GET", "/_synapse/admin/v1/server_version", nil, nil)
		if err == nil || !strings.Contains(err.Error(), "HTTP 404") {
			return fmt.Errorf("expected 404, got %v", err)
		}
		return nil
	}())

	pw, err := s.Secrets.Need("ADMIN_PASSWORD")
	if err != nil {
		return err
	}
	var login struct {
		AccessToken string `json:"access_token"`
	}
	if !k.check("password login as "+s.OwnerMXID(), c.do("POST", "/_matrix/client/v3/login", map[string]any{
		"type":                        "m.login.password",
		"identifier":                  map[string]string{"type": "m.id.user", "user": s.Settings.Owner},
		"password":                    pw,
		"initial_device_display_name": "sb test",
	}, &login)) {
		return fmt.Errorf("%d check(s) failed", k.failed)
	}
	c.token = login.AccessToken
	defer c.do("POST", "/_matrix/client/v3/logout", map[string]any{}, nil)

	k.check("simplified sliding sync available", c.do("POST",
		"/_matrix/client/unstable/org.matrix.simplified_msc3575/sync?timeout=0",
		map[string]any{"lists": map[string]any{"all": map[string]any{"ranges": [][]int{{0, 0}}, "timeline_limit": 0, "required_state": [][]string{}}}}, nil))

	var hub struct {
		Bridges []struct {
			ID, Network, Provisioning, Error string
			Reachable                        bool
		}
	}
	k.check("hub lists bridges", c.do("GET", "/_switchboard/v1/bridges", nil, &hub))

	if p := s.Settings.Push; p != nil {
		fmt.Println("push")
		_, err := sygnalProbe(s, "")
		k.check("synapse reaches sygnal", err)
		// A made-up device token: APNs only says "bad token" once it has
		// accepted the key.
		out, err := sygnalProbe(s, p.Topic+".dev")
		if err == nil && !strings.Contains(out, `"rejected"`) {
			err = fmt.Errorf("unexpected answer: %s", out)
		}
		k.check("APNs accepts the key (sandbox)", err)
	}

	bridges, err := s.PreparedBridges()
	if err != nil {
		return err
	}
	for _, b := range bridges {
		fmt.Printf("%s (%s)\n", b.ID, b.Network)
		reg, err := readRegistration(s.Path("appservices", b.ID+".yaml"))
		if !k.check("registration readable", err) {
			continue
		}
		as := &client{base: localURL, token: reg.ASToken, http: hc}
		k.check("homeserver reaches bridge (appservice ping)",
			as.do("POST", "/_matrix/client/v1/appservice/"+url.PathEscape(reg.ID)+"/ping", map[string]any{"transaction_id": "sb-test"}, nil))
		for _, h := range hub.Bridges {
			if h.ID == b.ID && h.Provisioning == "api" {
				var err error
				if !h.Reachable {
					err = fmt.Errorf("%s", h.Error)
				}
				k.check("hub reaches provisioning API", err)
			}
		}
		bot, err := s.BotMXID(b.Bridge)
		if k.check("bot user known", err) {
			k.check("bot answers a command", botRoundTrip(c, bot))
		}
	}
	if k.failed > 0 {
		return fmt.Errorf("%d check(s) failed", k.failed)
	}
	fmt.Println("All checks passed.")
	return nil
}

type registration struct {
	ID      string `yaml:"id"`
	ASToken string `yaml:"as_token"`
}

func readRegistration(path string) (registration, error) {
	var r registration
	data, err := os.ReadFile(path)
	if err == nil {
		err = yaml.Unmarshal(data, &r)
	}
	return r, err
}

// botRoundTrip opens a DM with a bridge bot, sends "help", waits for any
// reply from the bot, then leaves and forgets the room.
func botRoundTrip(c *client, bot string) error {
	var room struct {
		RoomID string `json:"room_id"`
	}
	if err := c.do("POST", "/_matrix/client/v3/createRoom", map[string]any{
		"preset": "trusted_private_chat", "is_direct": true, "invite": []string{bot}, "name": "sb test",
	}, &room); err != nil {
		return err
	}
	rid := url.PathEscape(room.RoomID)
	defer func() {
		c.do("POST", "/_matrix/client/v3/rooms/"+rid+"/leave", map[string]any{}, nil)
		c.do("POST", "/_matrix/client/v3/rooms/"+rid+"/forget", map[string]any{}, nil)
	}()

	deadline := time.Now().Add(30 * time.Second)
	for {
		var members struct {
			Joined map[string]any `json:"joined"`
		}
		if err := c.do("GET", "/_matrix/client/v3/rooms/"+rid+"/joined_members", nil, &members); err != nil {
			return err
		}
		if _, ok := members.Joined[bot]; ok {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s did not join within 30s", bot)
		}
		time.Sleep(time.Second)
	}

	txn := fmt.Sprintf("sbtest%d", time.Now().UnixNano())
	var sent struct {
		EventID string `json:"event_id"`
	}
	if err := c.do("PUT", "/_matrix/client/v3/rooms/"+rid+"/send/m.room.message/"+txn,
		map[string]string{"msgtype": "m.text", "body": "help"}, &sent); err != nil {
		return err
	}
	deadline = time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		var raw struct {
			Chunk []struct {
				Sender  string `json:"sender"`
				Type    string `json:"type"`
				EventID string `json:"event_id"`
			} `json:"chunk"`
		}
		if err := c.do("GET", "/_matrix/client/v3/rooms/"+rid+"/messages?dir=b&limit=20", nil, &raw); err != nil {
			return err
		}
		for _, ev := range raw.Chunk {
			if ev.EventID == sent.EventID {
				break // older than our command
			}
			if ev.Sender == bot && ev.Type == "m.room.message" {
				return nil
			}
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("no reply from %s within 30s", bot)
}

// sygnalProbe calls Sygnal from the Synapse container, where pushes start.
// With no app ID it checks /health; with one it sends a push for a made-up
// device token and returns Sygnal's answer.
func sygnalProbe(s *stack.Stack, appID string) (string, error) {
	const script = `import json, sys, urllib.request
app = sys.argv[1]
if not app:
    print(urllib.request.urlopen("http://sygnal:5000/health", timeout=10).status)
    sys.exit()
device = {"app_id": app, "pushkey": "0" * 64, "pushkey_ts": 0,
          "data": {"format": "event_id_only", "default_payload": {"aps": {"alert": "sb test"}}}}
body = {"notification": {"event_id": "$sbtest", "room_id": "!sbtest:sb", "counts": {"unread": 1}, "devices": [device]}}
req = urllib.request.Request("http://sygnal:5000/_matrix/push/v1/notify", json.dumps(body).encode(),
                             {"Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=30).read().decode())`
	out, err := s.ComposeOutput("", "exec", "-T", "synapse", "python", "-c", script, appID)
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(out))
	}
	return strings.TrimSpace(out), nil
}
