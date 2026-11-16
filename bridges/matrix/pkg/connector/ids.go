package connector

import (
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/id"
)

// The outside network's IDs are Matrix IDs already, so they pass through.

func makeLoginID(u id.UserID) networkid.UserLoginID  { return networkid.UserLoginID(u) }
func makeUserID(u id.UserID) networkid.UserID        { return networkid.UserID(u) }
func remoteUserID(u networkid.UserID) id.UserID      { return id.UserID(u) }
func makeMessageID(e id.EventID) networkid.MessageID { return networkid.MessageID(e) }
func remoteEventID(m networkid.MessageID) id.EventID { return id.EventID(m) }
func remoteRoomID(p networkid.PortalID) id.RoomID    { return id.RoomID(p) }

// Every portal belongs to one login: two linked accounts in the same
// outside room get a portal each.
func (mc *MatrixClient) portalKey(room id.RoomID) networkid.PortalKey {
	return networkid.PortalKey{ID: networkid.PortalID(room), Receiver: mc.login.ID}
}

func (mc *MatrixClient) sender(u id.UserID) bridgev2.EventSender {
	if u == mc.cli.UserID {
		return bridgev2.EventSender{IsFromMe: true, SenderLogin: mc.login.ID, Sender: makeUserID(u)}
	}
	return bridgev2.EventSender{Sender: makeUserID(u)}
}
