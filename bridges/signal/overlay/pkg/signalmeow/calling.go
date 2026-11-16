// Switchboard addition to mautrix-signal. AGPL-3.0-or-later, like the bridge.

package signalmeow

import (
	"context"
	"encoding/json"
	"net/http"

	"go.mau.fi/mautrix-signal/pkg/signalmeow/web"
)

// GetCallingRelays fetches Signal's TURN servers for 1:1 calls. The body is
// passed through as is:
// {"relays":[{"username","password","urls","urlsWithIps","hostname","ttl"}]}
func (cli *Client) GetCallingRelays(ctx context.Context) (json.RawMessage, error) {
	resp, err := cli.AuthedWS.SendRequest(ctx, http.MethodGet, "/v2/calling/relays", nil, nil)
	if err != nil {
		return nil, err
	}
	return resp.Body, web.DecodeWSResponseBody(ctx, nil, resp)
}
