// Command sb manages a Switchboard install: configs, secrets, bridges and the
// Docker Compose project that runs them.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"

	"switchboard/sb/internal/stack"
)

const usage = `sb manages the Switchboard backend.

Usage:
  sb init [--owner NAME] [--domain DOMAIN] [--public-url URL]
  sb up | down | status | render
  sb enable BRIDGE... | disable BRIDGE...
  sb bridges                 list the catalogue and what is enabled
  sb test                    smoke-test Synapse, the Hub and every bridge
  sb logs [SERVICE]          follow logs
  sb tailscale-key KEY       join the tailnet with a one-time auth key
  sb tailscale-login         show the login link for the switchboard node
  sb push KEY_ID TEAM_ID TOPIC  turn on iOS push through Sygnal (key at secrets/apns.p8)
  sb secret set NAME VALUE | sb secret get NAME
  sb compose ARGS...         run docker compose in the deploy directory
`

func main() {
	if len(os.Args) < 2 || os.Args[1] == "-h" || os.Args[1] == "--help" || os.Args[1] == "help" {
		fmt.Print(usage)
		return
	}
	if err := run(os.Args[1], os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, "sb:", err)
		os.Exit(1)
	}
}

func run(cmd string, args []string) error {
	wd, _ := os.Getwd()
	s, err := stack.Open(wd)
	if err != nil {
		return err
	}
	if cmd != "init" && cmd != "bridges" && cmd != "secret" && !s.Initialised() {
		// switchboard.yaml is git-ignored; a fresh checkout has only the example.
		return errors.New("not initialised yet; run: sb init, or copy switchboard.example.yaml to switchboard.yaml, fill it in and run sb init")
	}
	switch cmd {
	case "init":
		return cmdInit(s, args)
	case "up":
		return up(s)
	case "down":
		return s.Compose("down")
	case "status":
		return s.Compose("ps", "--format", "table {{.Service}}\t{{.Status}}\t{{.Image}}")
	case "render":
		return s.RenderCore()
	case "enable":
		return enable(s, args)
	case "disable":
		return disable(s, args)
	case "bridges":
		return listBridges(s)
	case "test":
		return smokeTest(s)
	case "logs":
		return s.Compose(append([]string{"logs", "-f", "--tail", "100"}, args...)...)
	case "tailscale-key":
		return tailscaleKey(s, args)
	case "tailscale-login":
		return s.Compose("logs", "--no-log-prefix", "tailscale")
	case "secret":
		return secret(s, args)
	case "push":
		return push(s, args)
	case "compose":
		return s.Compose(args...)
	default:
		return fmt.Errorf("unknown command %q\n\n%s", cmd, usage)
	}
}

func cmdInit(s *stack.Stack, args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	owner := fs.String("owner", "", "localpart of your Matrix account (required on first init)")
	domain := fs.String("domain", "switchboard.internal", "Matrix server name; permanent")
	publicURL := fs.String("public-url", "", "HTTPS URL devices use (default: https://switchboard.<your tailnet>)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !s.Initialised() {
		if *owner == "" {
			return fmt.Errorf("pass --owner NAME, the username for your Matrix account")
		}
		if *publicURL == "" {
			suffix, err := tailnetSuffix()
			if err != nil {
				return fmt.Errorf("can't work out your tailnet name (%w); pass --public-url, or copy switchboard.example.yaml to switchboard.yaml and fill it in", err)
			}
			*publicURL = "https://switchboard." + suffix
		}
		s.Settings = stack.Settings{Domain: *domain, Owner: *owner, PublicURL: *publicURL, Bridges: []string{}}
		if err := s.SaveSettings(); err != nil {
			return err
		}
	}
	if err := up(s); err != nil {
		return err
	}
	if err := s.CreateAdmin(); err != nil {
		return err
	}
	fmt.Printf(`
Switchboard is up.
  Homeserver URL  %s  (local: http://127.0.0.1:8080)
  Account         %s
  Password        stored as ADMIN_PASSWORD in %s/secrets.env
Next:
  sb tailscale-login     approve the switchboard node on your tailnet
  sb enable whatsapp     link your first network
`, s.Settings.PublicURL, s.OwnerMXID(), s.Secrets.Dir())
	return nil
}

func tailnetSuffix() (string, error) {
	out, err := exec.Command("tailscale", "status", "--json").Output()
	if err != nil {
		return "", err
	}
	var st struct {
		CurrentTailnet struct{ MagicDNSSuffix string }
	}
	if err := json.Unmarshal(out, &st); err != nil || st.CurrentTailnet.MagicDNSSuffix == "" {
		return "", errors.New("no MagicDNS suffix in tailscale status")
	}
	return st.CurrentTailnet.MagicDNSSuffix, nil
}

// up renders everything and brings the stack to a healthy state.
func up(s *stack.Stack) error {
	if err := s.RenderCore(); err != nil {
		return err
	}
	if err := s.Compose("up", "-d", "--wait", "postgres"); err != nil {
		return err
	}
	if err := s.EnsureDatabases(); err != nil {
		return err
	}
	return s.Compose("up", "-d", "--build", "--wait", "--remove-orphans")
}

func enable(s *stack.Stack, ids []string) error {
	if len(ids) == 0 {
		return errors.New("usage: sb enable BRIDGE...")
	}
	for _, id := range ids {
		b, err := s.Bridge(id)
		if err != nil {
			return err
		}
		fmt.Printf("Preparing %s (%s)...\n", b.ID, b.Network)
		if err := s.PrepareBridge(b); err != nil {
			return err
		}
		if !slices.Contains(s.Settings.Bridges, id) {
			s.Settings.Bridges = append(s.Settings.Bridges, id)
		}
	}
	if err := s.SaveSettings(); err != nil {
		return err
	}
	return applyBridgeChange(s)
}

func disable(s *stack.Stack, ids []string) error {
	for _, id := range ids {
		if _, err := s.Bridge(id); err != nil {
			return err
		}
		s.Settings.Bridges = slices.DeleteFunc(s.Settings.Bridges, func(b string) bool { return b == id })
	}
	if err := s.SaveSettings(); err != nil {
		return err
	}
	fmt.Println("Bridge configs and databases are kept; re-enabling picks up where you left off.")
	return applyBridgeChange(s)
}

// applyBridgeChange re-renders and recreates Synapse (it reads appservice
// registrations only at startup) and the Hub (it reads its bridge list at
// startup) before starting or removing bridge containers. Bridges that start
// first would have their tokens rejected and crash-loop.
func applyBridgeChange(s *stack.Stack) error {
	if err := s.RenderCore(); err != nil {
		return err
	}
	if err := s.Compose("up", "-d", "--wait", "postgres"); err != nil {
		return err
	}
	if err := s.EnsureDatabases(); err != nil {
		return err
	}
	if err := s.Compose("up", "-d", "--build", "--wait", "--force-recreate", "--no-deps", "synapse", "hub"); err != nil {
		return err
	}
	return s.Compose("up", "-d", "--build", "--wait", "--remove-orphans")
}

func listBridges(s *stack.Stack) error {
	ids := make([]string, 0, len(s.Catalogue))
	for id := range s.Catalogue {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	fmt.Printf("%-10s %-16s %-9s %-24s %s\n", "ID", "NETWORK", "KIND", "IMAGE TAG", "ENABLED")
	for _, id := range ids {
		b := s.Catalogue[id]
		img, _ := s.Image(b)
		_, tag, _ := strings.Cut(img, ":")
		on := ""
		if slices.Contains(s.Settings.Bridges, id) {
			on = "yes"
		}
		fmt.Printf("%-10s %-16s %-9s %-24s %s\n", id, b.Network, b.Kind, tag, on)
	}
	return nil
}

func secret(s *stack.Stack, args []string) error {
	switch {
	case len(args) == 3 && args[0] == "set":
		return s.Secrets.Set(args[1], args[2])
	case len(args) == 2 && args[0] == "get":
		v, err := s.Secrets.Need(args[1])
		if err != nil {
			return err
		}
		fmt.Println(v)
		return nil
	}
	return errors.New("usage: sb secret set NAME VALUE | sb secret get NAME")
}

// tailscaleKey stores a one-time auth key and recreates the sidecar so it
// joins the tailnet as "switchboard". The key is only used for first login;
// the node's identity then lives in the ts-state volume.
func tailscaleKey(s *stack.Stack, args []string) error {
	if len(args) != 1 || !strings.HasPrefix(args[0], "tskey-") {
		return errors.New("usage: sb tailscale-key tskey-auth-...")
	}
	path := s.Path("secrets", "tailscale.env")
	if err := os.WriteFile(path, []byte("TS_AUTHKEY="+args[0]+"\n"), 0o600); err != nil {
		return err
	}
	if err := s.Compose("up", "-d", "--force-recreate", "--wait", "tailscale"); err != nil {
		return err
	}
	// The container reports healthy before the login with the key finishes.
	for deadline := time.Now().Add(time.Minute); ; time.Sleep(2 * time.Second) {
		out, err := s.ComposeOutput("", "exec", "-T", "tailscale", "tailscale", "status", "--json", "--peers=false")
		var st struct {
			BackendState string
			Self         struct{ Online bool }
		}
		// Skip any compose warnings before the JSON.
		if i := strings.IndexByte(out, '{'); err == nil && i >= 0 && json.NewDecoder(strings.NewReader(out[i:])).Decode(&st) == nil && st.BackendState == "Running" && st.Self.Online {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("tailscale did not log in within a minute (state %q); see sb logs tailscale", st.BackendState)
		}
	}
	return s.Compose("exec", "tailscale", "tailscale", "status", "--self", "--peers=false")
}

// push turns on iOS push: Sygnal with the APNs key, and Synapse allowed to
// reach it inside the Compose network.
func push(s *stack.Stack, args []string) error {
	if len(args) != 3 {
		return errors.New("usage: sb push KEY_ID TEAM_ID TOPIC, with the APNs key at secrets/apns.p8")
	}
	if _, err := os.Stat(s.Path("secrets", "apns.p8")); err != nil {
		return fmt.Errorf("put the APNs key at %s first", s.Path("secrets", "apns.p8"))
	}
	s.Settings.Push = &stack.PushSettings{KeyID: args[0], TeamID: args[1], Topic: args[2]}
	if err := s.SaveSettings(); err != nil {
		return err
	}
	if err := s.RenderCore(); err != nil {
		return err
	}
	if err := s.Compose("up", "-d", "--wait", "sygnal"); err != nil {
		return err
	}
	// Synapse reads ip_range_whitelist only at start.
	if err := s.Compose("restart", "synapse"); err != nil {
		return err
	}
	return s.Compose("up", "-d", "--wait", "synapse")
}
