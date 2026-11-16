package yamlmerge

import (
	"errors"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func parse(t *testing.T, s string) *yaml.Node {
	t.Helper()
	var n yaml.Node
	if err := yaml.Unmarshal([]byte(s), &n); err != nil {
		t.Fatal(err)
	}
	return &n
}

func render(t *testing.T, n *yaml.Node) string {
	t.Helper()
	out, err := yaml.Marshal(n)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

const base = `homeserver:
    # The address that this appservice can use to connect to the homeserver.
    address: http://example.localhost:8008
    domain: example.com
    status_endpoint: null
bridge:
    permissions:
        "*": relay
        "example.com": user
appservice:
    port: 29318
`

func TestMergeKeepsCommentsAndOverridesScalars(t *testing.T) {
	b := parse(t, base)
	err := Merge(b, parse(t, `homeserver:
  address: http://synapse:8008
  status_endpoint: http://hub:8090/internal/bridge-state/whatsapp
`))
	if err != nil {
		t.Fatal(err)
	}
	out := render(t, b)
	for _, want := range []string{
		"# The address that this appservice can use",
		"address: http://synapse:8008",
		"domain: example.com",
		"status_endpoint: http://hub:8090/internal/bridge-state/whatsapp",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestMergeRejectsUnknownKeys(t *testing.T) {
	err := Merge(parse(t, base), parse(t, "homeserver:\n  adress: typo\n"))
	var unknown *UnknownKeyError
	if !errors.As(err, &unknown) || unknown.Path != "homeserver.adress" {
		t.Fatalf("want UnknownKeyError for homeserver.adress, got %v", err)
	}
}

func TestReplaceTagSwapsWholeMap(t *testing.T) {
	b := parse(t, base)
	err := Merge(b, parse(t, `bridge:
  permissions: !replace
    "switchboard.internal": user
    "@richard:switchboard.internal": admin
`))
	if err != nil {
		t.Fatal(err)
	}
	out := render(t, b)
	if strings.Contains(out, "relay") || strings.Contains(out, ReplaceTag) {
		t.Errorf("old keys or tag survived:\n%s", out)
	}
	if !strings.Contains(out, `'@richard:switchboard.internal': admin`) && !strings.Contains(out, `"@richard:switchboard.internal": admin`) {
		t.Errorf("new permission missing:\n%s", out)
	}
}

func TestLookupPath(t *testing.T) {
	if n := LookupPath(parse(t, base), "appservice.port"); n == nil || n.Value != "29318" {
		t.Fatalf("got %v", n)
	}
	if n := LookupPath(parse(t, base), "appservice.missing"); n != nil {
		t.Fatalf("want nil, got %v", n)
	}
}
