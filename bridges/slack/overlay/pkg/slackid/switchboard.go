// Switchboard addition to mautrix-slack. AGPL-3.0-or-later, like the bridge.

package slackid

import (
	"maunium.net/go/mautrix/bridgev2/database"
)

var _ database.MetaMerger = (*UserLoginMetadata)(nil)

// CopyFrom takes the credentials of a fresh login and keeps Switchboard's
// channel selection, so relinking an account doesn't forget which channels
// it bridges. Without it a relink replaces the metadata whole.
func (ulm *UserLoginMetadata) CopyFrom(incoming any) {
	incomingMeta, ok := incoming.(*UserLoginMetadata)
	if !ok || incomingMeta == nil {
		return
	}
	ulm.Email = incomingMeta.Email
	ulm.Token = incomingMeta.Token
	ulm.CookieToken = incomingMeta.CookieToken
	ulm.AppToken = incomingMeta.AppToken
}
