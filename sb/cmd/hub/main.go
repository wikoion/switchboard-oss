// Command hub is Switchboard's control plane. It gives the apps one API for
// bridge status and account linking, and receives the bridges' state pushes.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

type config struct {
	Listen     string         `yaml:"listen"`
	Owner      string         `yaml:"owner"`
	Homeserver string         `yaml:"homeserver"`
	Bridges    []bridgeConfig `yaml:"bridges"`
	// Push, when set, makes the hub Synapse's push gateway, in front of
	// Sygnal.
	Push *pushConfig `yaml:"push"`
}

type pushConfig struct {
	Gateway string `yaml:"gateway"`
	ASToken string `yaml:"as_token"`
}

type bridgeConfig struct {
	ID      string `yaml:"id" json:"id"`
	Network string `yaml:"network" json:"network"`
	Kind    string `yaml:"kind" json:"kind"`
	URL     string `yaml:"url" json:"-"`
}

func main() {
	path := flag.String("config", "/config/hub.yaml", "path to hub.yaml")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	var cfg config
	data, err := os.ReadFile(*path)
	if err == nil {
		err = yaml.Unmarshal(data, &cfg)
	}
	if err != nil {
		log.Error("reading config", "err", err)
		os.Exit(1)
	}
	srv := newServer(cfg, log)
	if srv.push != nil {
		go srv.push.muteInvites(context.Background(), log)
	}
	log.Info("hub listening", "addr", cfg.Listen, "bridges", len(cfg.Bridges))
	if err := http.ListenAndServe(cfg.Listen, srv.routes()); err != nil {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

type server struct {
	cfg     config
	log     *slog.Logger
	http    *http.Client
	auth    *authCache
	states  *stateStore
	bridges map[string]bridgeConfig
	proxies map[string]*httputil.ReverseProxy
	broker  *broker
	push    *pushFilter
}

func newServer(cfg config, log *slog.Logger) *server {
	s := &server{
		cfg:     cfg,
		log:     log,
		http:    &http.Client{Timeout: 10 * time.Second},
		states:  &stateStore{byBridge: map[string]map[string]bridgeState{}},
		bridges: map[string]bridgeConfig{},
		proxies: map[string]*httputil.ReverseProxy{},
		broker:  newBroker(),
	}
	s.auth = &authCache{homeserver: cfg.Homeserver, client: s.http, ttl: 5 * time.Minute, entries: map[[32]byte]authEntry{}}
	for _, b := range cfg.Bridges {
		s.bridges[b.ID] = b
		s.proxies[b.ID] = provisioningProxy(b.URL, cfg.Owner)
	}
	if cfg.Push != nil {
		s.push = &pushFilter{
			gateway: cfg.Push.Gateway, homeserver: cfg.Homeserver, asToken: cfg.Push.ASToken, owner: cfg.Owner,
			http: s.http, created: map[string]time.Time{},
		}
	}
	return s
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	mux.Handle("GET /_switchboard/v1/bridges", s.ownerOnly(s.listBridges))
	mux.Handle("/_switchboard/v1/bridges/{id}/provision/{rest...}", s.ownerOnly(s.provision))
	mux.Handle("GET /_switchboard/v1/events", s.ownerOnly(s.events))
	// Internal endpoints: Caddy only forwards /_switchboard/*, so these are
	// reachable from the Compose network alone.
	mux.HandleFunc("POST /internal/bridge-state/{id}", s.receiveBridgeState)
	mux.HandleFunc("POST /internal/checkpoint/{id}", s.receiveCheckpoint)
	if s.push != nil {
		// Synapse's pusher posts here; Caddy doesn't forward /_matrix/push.
		mux.HandleFunc("POST /_matrix/push/v1/notify", s.notify)
	}
	return mux
}

// ownerOnly admits requests carrying the owner's Matrix access token.
func (s *server) ownerOnly(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			writeError(w, http.StatusUnauthorized, "M_MISSING_TOKEN", "missing access token")
			return
		}
		user, err := s.auth.whoami(r.Context(), token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "invalid access token")
			return
		}
		if user != s.cfg.Owner {
			writeError(w, http.StatusForbidden, "M_FORBIDDEN", "only the owner may use the hub")
			return
		}
		next(w, r)
	})
}

type bridgeStatus struct {
	bridgeConfig
	Provisioning string          `json:"provisioning"`
	Reachable    bool            `json:"reachable"`
	Error        string          `json:"error,omitempty"`
	Whoami       json.RawMessage `json:"whoami,omitempty"`
	States       []bridgeState   `json:"states"`
}

func (s *server) listBridges(w http.ResponseWriter, r *http.Request) {
	out := make([]bridgeStatus, len(s.cfg.Bridges))
	var wg sync.WaitGroup
	for i, b := range s.cfg.Bridges {
		out[i] = bridgeStatus{bridgeConfig: b, Provisioning: "api", States: s.states.list(b.ID)}
		if b.Kind != "bridgev2" {
			out[i].Provisioning = "bot"
			continue
		}
		wg.Add(1)
		go func(st *bridgeStatus) {
			defer wg.Done()
			st.Whoami, st.Error = s.bridgeWhoami(r, st.URL)
			st.Reachable = st.Error == ""
		}(&out[i])
	}
	wg.Wait()
	writeJSON(w, http.StatusOK, map[string]any{"bridges": out})
}

func (s *server) bridgeWhoami(r *http.Request, base string) (json.RawMessage, string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/_matrix/provision/v3/whoami?user_id="+url.QueryEscape(s.cfg.Owner), nil)
	req.Header.Set("Authorization", r.Header.Get("Authorization"))
	resp, err := s.http.Do(req)
	if err != nil {
		return nil, err.Error()
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Sprintf("whoami: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, ""
}

func (s *server) provision(w http.ResponseWriter, r *http.Request) {
	proxy, ok := s.proxies[r.PathValue("id")]
	if !ok {
		writeError(w, http.StatusNotFound, "M_NOT_FOUND", "unknown bridge")
		return
	}
	proxy.ServeHTTP(w, r)
}

// provisioningProxy forwards /_switchboard/v1/bridges/{id}/provision/<rest>
// to <bridge>/_matrix/provision/<rest>, keeping the caller's token. Bridges
// check a Matrix token against the user_id query parameter; ownerOnly has
// already established that the caller is the owner.
func provisioningProxy(base, owner string) *httputil.ReverseProxy {
	target, _ := url.Parse(base)
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.URL.Path = "/_matrix/provision/" + pr.In.PathValue("rest")
			pr.Out.URL.RawPath = ""
			q := pr.Out.URL.Query()
			q.Set("user_id", owner)
			pr.Out.URL.RawQuery = q.Encode()
			pr.SetXForwarded()
		},
		FlushInterval: -1,
	}
}

// bridgeState is one push from a bridge's status_endpoint.
type bridgeState struct {
	StateEvent string          `json:"state_event"`
	Timestamp  int64           `json:"timestamp"`
	Error      string          `json:"error,omitempty"`
	Message    string          `json:"message,omitempty"`
	UserID     string          `json:"user_id,omitempty"`
	RemoteID   string          `json:"remote_id,omitempty"`
	RemoteName string          `json:"remote_name,omitempty"`
	Info       json.RawMessage `json:"info,omitempty"`
	ReceivedAt time.Time       `json:"received_at"`
}

type stateStore struct {
	mu       sync.Mutex
	byBridge map[string]map[string]bridgeState
}

func (st *stateStore) put(bridge string, s bridgeState) (previous string) {
	st.mu.Lock()
	defer st.mu.Unlock()
	m := st.byBridge[bridge]
	if m == nil {
		m = map[string]bridgeState{}
		st.byBridge[bridge] = m
	}
	previous = m[s.RemoteID].StateEvent
	m[s.RemoteID] = s
	return previous
}

func (st *stateStore) list(bridge string) []bridgeState {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := []bridgeState{}
	for _, s := range st.byBridge[bridge] {
		out = append(out, s)
	}
	return out
}

func (s *server) receiveBridgeState(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := s.bridges[id]; !ok {
		writeError(w, http.StatusNotFound, "M_NOT_FOUND", "unknown bridge")
		return
	}
	var st bridgeState
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&st); err != nil {
		writeError(w, http.StatusBadRequest, "M_BAD_JSON", err.Error())
		return
	}
	st.ReceivedAt = time.Now()
	if prev := s.states.put(id, st); prev != st.StateEvent {
		s.log.Info("bridge state", "bridge", id, "remote", st.RemoteName, "from", prev, "to", st.StateEvent, "error", st.Error)
		s.broker.publish(hubEvent{Type: "bridge_state", Bridge: id, State: st})
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) receiveCheckpoint(w http.ResponseWriter, r *http.Request) {
	// Recorded for the "why didn't this send?" view in a later milestone.
	io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20))
	w.WriteHeader(http.StatusNoContent)
}

type authEntry struct {
	user    string
	expires time.Time
}

type authCache struct {
	homeserver string
	client     *http.Client
	ttl        time.Duration
	mu         sync.Mutex
	entries    map[[32]byte]authEntry
}

func (a *authCache) whoami(ctx context.Context, token string) (string, error) {
	key := sha256.Sum256([]byte(token))
	a.mu.Lock()
	e, ok := a.entries[key]
	a.mu.Unlock()
	if ok && time.Now().Before(e.expires) {
		return e.user, nil
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, a.homeserver+"/_matrix/client/v3/account/whoami", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := a.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", errors.New(resp.Status)
	}
	var body struct {
		UserID string `json:"user_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	a.mu.Lock()
	a.entries[key] = authEntry{user: body.UserID, expires: time.Now().Add(a.ttl)}
	a.mu.Unlock()
	return body.UserID, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"errcode": code, "error": msg})
}
