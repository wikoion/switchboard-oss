package stack

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"text/template"

	"gopkg.in/yaml.v3"

	"switchboard/sb/internal/yamlmerge"
)

// BridgeRef is a prepared bridge as the templates see it.
type BridgeRef struct {
	*Bridge
	Port  int
	Image string
	URL   string
}

type coreData struct {
	Domain, PublicURL, OwnerMXID, OwnerRegex           string
	SynapseDBPassword, RegistrationSecret              string
	MacaroonSecret, FormSecret                         string
	DoublePuppetAS, DoublePuppetHS, DoublePuppetSender string
	AppServices                                        []string
	Bridges                                            []BridgeRef
	Push                                               *PushSettings
}

type bridgeData struct {
	ID, Domain, OwnerMXID, HubURL string
	Port                          int
	DBName, DBUser, DBPassword    string
	ProvisioningSecret            string
	DoublePuppetAS                string
}

// RenderCore writes every generated file except the bridges' own configs:
// .env, Synapse, Caddy, Tailscale and Hub configs, the double-puppet
// registration and compose.bridges.yml.
func (s *Stack) RenderCore() error {
	bridges, err := s.PreparedBridges()
	if err != nil {
		return err
	}
	d := coreData{
		Domain:     s.Settings.Domain,
		PublicURL:  strings.TrimRight(s.Settings.PublicURL, "/"),
		OwnerMXID:  s.OwnerMXID(),
		OwnerRegex: "@" + regexp.QuoteMeta(s.Settings.Owner) + ":" + regexp.QuoteMeta(s.Settings.Domain),
		Bridges:    bridges,
		Push:       s.Settings.Push,
	}
	for name, dst := range map[string]*string{
		"SYNAPSE_DB_PASSWORD":        &d.SynapseDBPassword,
		"REGISTRATION_SHARED_SECRET": &d.RegistrationSecret,
		"MACAROON_SECRET":            &d.MacaroonSecret,
		"FORM_SECRET":                &d.FormSecret,
		"DOUBLEPUPPET_AS_TOKEN":      &d.DoublePuppetAS,
		"DOUBLEPUPPET_HS_TOKEN":      &d.DoublePuppetHS,
		"DOUBLEPUPPET_SENDER":        &d.DoublePuppetSender,
	} {
		if *dst, err = s.Secrets.Get(name); err != nil {
			return err
		}
	}
	d.DoublePuppetSender = "dp_" + d.DoublePuppetSender[:16]

	d.AppServices = []string{"doublepuppet.yaml"}
	for _, b := range bridges {
		d.AppServices = append(d.AppServices, b.ID+".yaml")
	}

	if err := s.writeEnv(); err != nil {
		return err
	}
	if err := s.ensureSigningKey(); err != nil {
		return err
	}
	if err := s.ensurePostgresRootSecret(); err != nil {
		return err
	}
	files := []struct{ tmpl, dst string }{
		{"homeserver.yaml.tmpl", "config/synapse/homeserver.yaml"},
		{"log.config", "config/synapse/log.config"},
		{"Caddyfile.tmpl", "config/caddy/Caddyfile"},
		{"serve.json", "config/tailscale/serve.json"},
		{"hub.yaml.tmpl", "config/hub/hub.yaml"},
		{"doublepuppet.yaml.tmpl", "appservices/doublepuppet.yaml"},
		{"compose.bridges.yml.tmpl", "compose.bridges.yml"},
	}
	if d.Push != nil {
		files = append(files, struct{ tmpl, dst string }{"sygnal.yaml.tmpl", "config/sygnal/sygnal.yaml"})
	}
	for _, f := range files {
		out, err := s.renderTemplate(s.Path("templates", f.tmpl), d)
		if err != nil {
			return err
		}
		if err := writeFile(s.Path(f.dst), out, 0o644); err != nil {
			return err
		}
	}
	return copyFile(s.Path("secrets", "signing.key"), s.Path("config", "synapse", "signing.key"))
}

// PreparedBridges returns the enabled bridges with ports read from their
// rendered configs.
func (s *Stack) PreparedBridges() ([]BridgeRef, error) {
	enabled, err := s.Enabled()
	if err != nil {
		return nil, err
	}
	var refs []BridgeRef
	for _, b := range enabled {
		node, err := readNode(s.Path("config", "bridges", b.ID, "config.yaml"))
		if err != nil {
			return nil, fmt.Errorf("bridge %s is enabled but not prepared (run: sb enable %s): %w", b.ID, b.ID, err)
		}
		port, err := bridgePort(node)
		if err != nil {
			return nil, fmt.Errorf("bridge %s: %w", b.ID, err)
		}
		img, err := s.Image(b)
		if err != nil {
			return nil, err
		}
		refs = append(refs, BridgeRef{Bridge: b, Port: port, Image: img, URL: fmt.Sprintf("http://%s:%d", b.Service(), port)})
	}
	return refs, nil
}

// PrepareBridge generates a bridge's config from the upstream example plus
// our overlays, then has the bridge generate its appservice registration.
func (s *Stack) PrepareBridge(b *Bridge) error {
	for _, name := range b.Requires {
		if _, err := s.Secrets.Need(name); err != nil {
			return fmt.Errorf("bridge %s: %w", b.ID, err)
		}
	}
	img, err := s.Image(b)
	if err != nil {
		return err
	}
	if b.Build != "" {
		if out, err := s.Docker("build", "-t", img, s.Path(b.Build)); err != nil {
			return fmt.Errorf("bridge %s: building %s: %w\n%s", b.ID, img, err, out)
		}
	}
	dir := s.Path("config", "bridges", b.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	cfgPath, regPath := filepath.Join(dir, "config.yaml"), filepath.Join(dir, "registration.yaml")

	if !exists(cfgPath) {
		if err := s.runBridgeOnce(img, dir, cfgPath); err != nil {
			return fmt.Errorf("bridge %s: generating example config: %w", b.ID, err)
		}
	}
	node, err := readNode(cfgPath)
	if err != nil {
		return err
	}
	port, err := bridgePort(node)
	if err != nil {
		return fmt.Errorf("bridge %s: %w", b.ID, err)
	}
	d := bridgeData{
		ID: b.ID, Domain: s.Settings.Domain, OwnerMXID: s.OwnerMXID(), HubURL: "http://hub:8090",
		Port: port, DBName: b.ID, DBUser: b.ID,
	}
	if d.DBPassword, err = s.Secrets.Get("DB_PASSWORD_" + strings.ToUpper(b.ID)); err != nil {
		return err
	}
	if d.ProvisioningSecret, err = s.Secrets.Get("PROVISIONING_SECRET_" + strings.ToUpper(b.ID)); err != nil {
		return err
	}
	if d.DoublePuppetAS, err = s.Secrets.Get("DOUBLEPUPPET_AS_TOKEN"); err != nil {
		return err
	}
	overlays := []string{s.Path("overlays", "shared-"+b.Kind+".yaml"), s.Path("overlays", b.ID+".yaml")}
	for _, path := range overlays {
		if !exists(path) {
			continue
		}
		out, err := s.renderTemplate(path, d)
		if err != nil {
			return err
		}
		var ov yaml.Node
		if err := yaml.Unmarshal(out, &ov); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if err := yamlmerge.Merge(&node, &ov); err != nil {
			return fmt.Errorf("bridge %s, overlay %s: %w", b.ID, filepath.Base(path), err)
		}
	}
	if err := writeNode(cfgPath, &node); err != nil {
		return err
	}
	if !exists(regPath) {
		if err := s.runBridgeOnce(img, dir, regPath); err != nil {
			return fmt.Errorf("bridge %s: generating registration: %w", b.ID, err)
		}
	}
	return copyFile(regPath, s.Path("appservices", b.ID+".yaml"))
}

// runBridgeOnce runs the bridge image's entrypoint, which writes the next
// missing file (example config, then registration) and exits.
func (s *Stack) runBridgeOnce(img, dir, want string) error {
	out, err := s.Docker("run", "--rm", "-v", dir+":/data", img)
	if !exists(want) {
		return fmt.Errorf("%s was not created (%v):\n%s", filepath.Base(want), err, out)
	}
	return nil
}

func bridgePort(node yaml.Node) (int, error) {
	n := yamlmerge.LookupPath(&node, "appservice.port")
	if n == nil {
		return 0, errors.New("config has no appservice.port")
	}
	return strconv.Atoi(n.Value)
}

func (s *Stack) renderTemplate(path string, data any) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	t, err := template.New(filepath.Base(path)).Option("missingkey=error").Funcs(template.FuncMap{
		"secret": s.Secrets.Need,
		"gen":    s.Secrets.Get,
	}).Parse(string(raw))
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func (s *Stack) writeEnv() error {
	keys := make([]string, 0, len(s.Versions))
	for k := range s.Versions {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var buf bytes.Buffer
	buf.WriteString("# Generated by sb from versions.env. Edit that file instead.\n")
	buf.WriteString("COMPOSE_PROJECT_NAME=switchboard\nCOMPOSE_FILE=compose.yaml:compose.bridges.yml\n")
	if s.Settings.Push != nil {
		buf.WriteString("COMPOSE_PROFILES=ios-push\n")
	}
	for _, k := range keys {
		fmt.Fprintf(&buf, "%s=%s\n", k, s.Versions[k])
	}
	return writeFile(s.Path(".env"), buf.Bytes(), 0o644)
}

// ensureSigningKey creates Synapse's ed25519 signing key in Synapse's own
// file format: "ed25519 <key id> <unpadded base64 seed>".
func (s *Stack) ensureSigningKey() error {
	path := s.Path("secrets", "signing.key")
	if exists(path) {
		return nil
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	id := make([]byte, 3)
	if _, err := rand.Read(id); err != nil {
		return err
	}
	line := fmt.Sprintf("ed25519 a_%x %s\n", id, base64.RawStdEncoding.EncodeToString(priv.Seed()))
	return writeFile(path, []byte(line), 0o600)
}

func (s *Stack) ensurePostgresRootSecret() error {
	pw, err := s.Secrets.Get("POSTGRES_ROOT_PASSWORD")
	if err != nil {
		return err
	}
	return writeFile(s.Path("secrets", "pg_root"), []byte(pw), 0o600)
}

func readNode(path string) (yaml.Node, error) {
	var n yaml.Node
	data, err := os.ReadFile(path)
	if err != nil {
		return n, err
	}
	if err := yaml.Unmarshal(data, &n); err != nil {
		return n, fmt.Errorf("%s: %w", path, err)
	}
	return n, nil
}

func writeNode(path string, n *yaml.Node) error {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(4)
	if err := enc.Encode(n); err != nil {
		return err
	}
	return writeFile(path, buf.Bytes(), 0o644)
}

func writeFile(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, mode)
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return writeFile(dst, data, 0o644)
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// BotMXID returns the bridge bot's user ID from its rendered config.
func (s *Stack) BotMXID(b *Bridge) (string, error) {
	node, err := readNode(s.Path("config", "bridges", b.ID, "config.yaml"))
	if err != nil {
		return "", err
	}
	n := yamlmerge.LookupPath(&node, "appservice.bot.username")
	if n == nil || n.Value == "" {
		return "", errors.New("config has no appservice.bot.username")
	}
	return "@" + n.Value + ":" + s.Settings.Domain, nil
}
