// Switchboard addition to mautrix-signal. AGPL-3.0-or-later, like the bridge.

package main

import (
	"net/http"

	"go.mau.fi/mautrix-signal/pkg/connector"
	"go.mau.fi/mautrix-signal/pkg/signalcall"
)

// Hooks the call signalling relay in without editing main.go. The Matrix
// event processor exists by PostInit; the provisioning router only by
// PostStart.
func init() {
	postInit, postStart := m.PostInit, m.PostStart
	m.PostInit = func() {
		if postInit != nil {
			postInit()
		}
		sc := m.Connector.(*connector.SignalConnector)
		m.Matrix.EventProcessor.On(signalcall.EventType, sc.HandleMatrixCallEvent)
	}
	m.PostStart = func() {
		if postStart != nil {
			postStart()
		}
		sc := m.Connector.(*connector.SignalConnector)
		prov := m.Matrix.Provisioning
		prov.GetRouter().HandleFunc("GET /v3/calls/config", func(w http.ResponseWriter, r *http.Request) {
			sc.GetCallsConfig(w, r, prov.GetUser(r))
		})
	}
}
