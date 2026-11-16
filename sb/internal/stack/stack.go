// Package stack models the Switchboard deployment: its settings, bridge
// catalogue, secrets and the Docker Compose project that runs it.
package stack

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Settings is deploy/switchboard.yaml: everything about this install that
// isn't secret. It is git-ignored; switchboard.example.yaml shows the shape.
type Settings struct {
	Domain    string        `yaml:"domain"`
	Owner     string        `yaml:"owner"`
	PublicURL string        `yaml:"public_url"`
	Bridges   []string      `yaml:"bridges"`
	Push      *PushSettings `yaml:"push,omitempty"`
}

// PushSettings turns on iOS push through Sygnal and APNs. The key itself is
// secrets/apns.p8.
type PushSettings struct {
	KeyID  string `yaml:"apns_key_id"`
	TeamID string `yaml:"apns_team_id"`
	Topic  string `yaml:"apns_topic"`
}

// Bridge is one entry of deploy/bridges.yaml.
type Bridge struct {
	ID       string   `yaml:"-"`
	Network  string   `yaml:"network"`
	Image    string   `yaml:"image"`
	TagVar   string   `yaml:"tag"`
	Kind     string   `yaml:"kind"`
	Requires []string `yaml:"requires"`
	// Build is a directory, relative to deploy/, holding the Dockerfile of
	// a bridge built here rather than pulled.
	Build string `yaml:"build"`
}

// Service is the Compose service name of a bridge.
func (b *Bridge) Service() string { return "mautrix-" + b.ID }

type Stack struct {
	Deploy    string
	Settings  Settings
	Catalogue map[string]*Bridge
	Versions  map[string]string
	Secrets   *Secrets
}

// Open finds the deploy directory by walking up from dir.
func Open(dir string) (*Stack, error) {
	deploy, err := findDeploy(dir)
	if err != nil {
		return nil, err
	}
	s := &Stack{Deploy: deploy}
	if err := readYAML(s.Path("bridges.yaml"), &s.Catalogue); err != nil {
		return nil, err
	}
	for id, b := range s.Catalogue {
		b.ID = id
	}
	if s.Versions, err = readEnv(s.Path("versions.env")); err != nil {
		return nil, err
	}
	if err := readYAML(s.Path("switchboard.yaml"), &s.Settings); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	s.Secrets, err = loadSecrets(s.Path("secrets"))
	return s, err
}

func findDeploy(dir string) (string, error) {
	dir, _ = filepath.Abs(dir)
	for {
		for _, cand := range []string{dir, filepath.Join(dir, "deploy")} {
			if _, err := os.Stat(filepath.Join(cand, "bridges.yaml")); err == nil {
				return cand, nil
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("no deploy/bridges.yaml found here or in any parent directory")
		}
		dir = parent
	}
}

func (s *Stack) Path(parts ...string) string {
	return filepath.Join(append([]string{s.Deploy}, parts...)...)
}

func (s *Stack) Initialised() bool { return s.Settings.Domain != "" }

func (s *Stack) OwnerMXID() string { return "@" + s.Settings.Owner + ":" + s.Settings.Domain }

func (s *Stack) SaveSettings() error {
	sort.Strings(s.Settings.Bridges)
	s.Settings.Bridges = slices.Compact(s.Settings.Bridges)
	out, err := yaml.Marshal(&s.Settings)
	if err != nil {
		return err
	}
	header := "# Switchboard install settings. Managed by sb; safe to edit by hand.\n"
	return os.WriteFile(s.Path("switchboard.yaml"), append([]byte(header), out...), 0o644)
}

// Enabled returns the enabled bridges in a stable order.
func (s *Stack) Enabled() ([]*Bridge, error) {
	var out []*Bridge
	for _, id := range s.Settings.Bridges {
		b, ok := s.Catalogue[id]
		if !ok {
			return nil, fmt.Errorf("switchboard.yaml enables unknown bridge %q", id)
		}
		out = append(out, b)
	}
	return out, nil
}

func (s *Stack) Bridge(id string) (*Bridge, error) {
	b, ok := s.Catalogue[id]
	if !ok {
		ids := make([]string, 0, len(s.Catalogue))
		for k := range s.Catalogue {
			ids = append(ids, k)
		}
		sort.Strings(ids)
		return nil, fmt.Errorf("unknown bridge %q (known: %s)", id, strings.Join(ids, ", "))
	}
	return b, nil
}

// Image returns the pinned image reference of a bridge.
func (s *Stack) Image(b *Bridge) (string, error) {
	tag, ok := s.Versions[b.TagVar]
	if !ok {
		return "", fmt.Errorf("versions.env has no %s for bridge %s", b.TagVar, b.ID)
	}
	return b.Image + ":" + tag, nil
}

// Compose runs docker compose in the deploy directory with stdio attached.
func (s *Stack) Compose(args ...string) error {
	cmd := s.composeCmd(args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

// ComposeOutput runs docker compose with the given stdin and returns its
// combined output.
func (s *Stack) ComposeOutput(stdin string, args ...string) (string, error) {
	cmd := s.composeCmd(args...)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (s *Stack) composeCmd(args ...string) *exec.Cmd {
	cmd := exec.Command("docker", append([]string{"compose", "--project-directory", s.Deploy}, args...)...)
	cmd.Dir = s.Deploy
	cmd.Env = s.dockerEnv()
	return cmd
}

// Docker runs a plain docker command, returning combined output.
func (s *Stack) Docker(args ...string) (string, error) {
	cmd := exec.Command("docker", args...)
	cmd.Env = s.dockerEnv()
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// dockerEnv points docker at a private config directory with no credential
// store. Every image Switchboard uses is public, and Docker Desktop's
// credential helper can block forever on a Keychain prompt nobody is at the
// Mac to answer. Your own ~/.docker/config.json is left untouched.
func (s *Stack) dockerEnv() []string {
	env := os.Environ()
	dir := s.Path(".docker")
	if !exists(filepath.Join(dir, "config.json")) {
		_ = os.MkdirAll(dir, 0o700)
		_ = os.WriteFile(filepath.Join(dir, "config.json"), []byte("{}\n"), 0o600)
		if home, err := os.UserHomeDir(); err == nil {
			_ = os.Symlink(filepath.Join(home, ".docker", "cli-plugins"), filepath.Join(dir, "cli-plugins"))
		}
	}
	if os.Getenv("DOCKER_HOST") == "" {
		if out, err := exec.Command("docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}").Output(); err == nil {
			env = append(env, "DOCKER_HOST="+strings.TrimSpace(string(out)))
		}
	}
	return append(env, "DOCKER_CONFIG="+dir)
}

// Secrets is deploy/secrets/secrets.env, a KEY=VALUE file kept at mode 600.
type Secrets struct {
	dir    string
	values map[string]string
}

func loadSecrets(dir string) (*Secrets, error) {
	values, err := readEnv(filepath.Join(dir, "secrets.env"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if values == nil {
		values = map[string]string{}
	}
	return &Secrets{dir: dir, values: values}, nil
}

// Get returns a secret, generating 32 random bytes of hex if it is missing.
func (s *Secrets) Get(name string) (string, error) {
	if v, ok := s.values[name]; ok {
		return v, nil
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	s.values[name] = hex.EncodeToString(b)
	return s.values[name], s.save()
}

// Need returns a secret the user must provide with `sb secret set`.
func (s *Secrets) Need(name string) (string, error) {
	if v, ok := s.values[name]; ok && v != "" {
		return v, nil
	}
	return "", fmt.Errorf("secret %s is not set; run: sb secret set %s <value>", name, name)
}

func (s *Secrets) Set(name, value string) error {
	s.values[name] = value
	return s.save()
}

func (s *Secrets) Dir() string { return s.dir }

func (s *Secrets) save() error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return err
	}
	keys := make([]string, 0, len(s.values))
	for k := range s.values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var buf bytes.Buffer
	buf.WriteString("# Generated by sb. Never commit this file.\n")
	for _, k := range keys {
		fmt.Fprintf(&buf, "%s=%s\n", k, s.values[k])
	}
	return os.WriteFile(filepath.Join(s.dir, "secrets.env"), buf.Bytes(), 0o600)
}

func readYAML(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := yaml.Unmarshal(data, v); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

func readEnv(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	values := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("%s: bad line %q", path, line)
		}
		values[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return values, sc.Err()
}
