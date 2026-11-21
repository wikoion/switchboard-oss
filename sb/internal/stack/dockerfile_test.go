package stack

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// buildScriptCall matches a call of one of upstream's build scripts in a
// Dockerfile RUN line, with whatever follows it up to the end of that
// command.
var buildScriptCall = regexp.MustCompile(`\./build[\w-]*\.sh([^&;|]*)`)

// buildScriptArgs returns what each call of an upstream build script in a
// Dockerfile passes to it, one entry per call ("" for none).
func buildScriptArgs(dockerfile string) []string {
	// A RUN instruction may run over several lines.
	joined := strings.ReplaceAll(dockerfile, "\\\n", " ")
	var args []string
	for _, line := range strings.Split(joined, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "RUN ") {
			continue
		}
		for _, m := range buildScriptCall.FindAllStringSubmatch(line, -1) {
			args = append(args, strings.TrimSpace(m[1]))
		}
	}
	return args
}

func TestBuildScriptArgs(t *testing.T) {
	for _, tc := range []struct {
		name, dockerfile string
		want             []string
	}{
		{"no arguments", "RUN ./build.sh\n", []string{""}},
		{"output flag", "RUN ./build.sh -o /usr/bin/mautrix-discord\n", []string{"-o /usr/bin/mautrix-discord"}},
		{"flag before a second command", "RUN ./build-go.sh -v && ls\n", []string{"-v"}},
		{"continued line", "RUN ./build.sh \\\n    -tags foo\n", []string{"-tags foo"}},
		{"two scripts", "RUN ./build-rust.sh\nRUN ./build-go.sh\n", []string{"", ""}},
		{"a comment is not a call", "# RUN ./build.sh -o x\nCOPY build.sh .\n", nil},
	} {
		got := buildScriptArgs(tc.dockerfile)
		if strings.Join(got, "|") != strings.Join(tc.want, "|") || len(got) != len(tc.want) {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

// The bridges built here run upstream's build scripts, which end
// `go build -ldflags=... ./cmd/<bridge> "$@"`: anything passed to them lands
// after the package path, where go reads it as another package and stops
// with `malformed import path "-o": leading dash`. The Discord image was
// added calling `./build.sh -o /usr/bin/mautrix-discord` and never built.
func TestBridgeDockerfilesPassNothingToUpstreamBuildScripts(t *testing.T) {
	deploy, err := findDeploy(".")
	if err != nil {
		t.Fatal(err)
	}
	var catalogue map[string]*Bridge
	if err := readYAML(filepath.Join(deploy, "bridges.yaml"), &catalogue); err != nil {
		t.Fatal(err)
	}
	built := 0
	for id, b := range catalogue {
		if b.Build == "" {
			continue
		}
		built++
		path := filepath.Join(deploy, b.Build, "Dockerfile")
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("bridge %s: build: %s has no Dockerfile: %v", id, b.Build, err)
			continue
		}
		for _, args := range buildScriptArgs(string(raw)) {
			if args != "" {
				t.Errorf("bridge %s: %s passes %q to an upstream build script, which go build reads as packages", id, path, args)
			}
		}
	}
	if built == 0 {
		t.Fatal("bridges.yaml lists no bridge built here; the test checked nothing")
	}
}
