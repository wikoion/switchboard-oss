// sb-matrix bridges outside Matrix accounts (matrix.org or any other
// homeserver) into Switchboard, the way the mautrix bridges bring in other
// networks. Switchboard's own server can't federate, so this is how it
// talks to the wider Matrix network.
package main

import (
	"maunium.net/go/mautrix/bridgev2/matrix/mxmain"

	"github.com/wikoion/switchboard-oss/bridges/matrix/pkg/connector"
)

// Filled at build time with -X.
var (
	Tag       = "unknown"
	Commit    = "unknown"
	BuildTime = "unknown"
)

var m = mxmain.BridgeMain{
	Name:        "sb-matrix",
	URL:         "https://github.com/wikoion/switchboard-oss",
	Description: "Switchboard's Matrix-to-Matrix puppeting bridge.",
	Version:     "0.1.0",
	Connector:   &connector.MatrixConnector{},
}

func main() {
	m.InitVersion(Tag, Commit, BuildTime)
	m.Run()
}
