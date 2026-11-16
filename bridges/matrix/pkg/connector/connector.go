// Package connector is a bridgev2 network connector whose "network" is
// another Matrix homeserver. Each login is an outside Matrix account; its
// rooms become portals on Switchboard's server, its contacts ghost users.
package connector

import (
	"context"

	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
)

type MatrixConnector struct {
	Bridge *bridgev2.Bridge
	Config Config
}

var _ bridgev2.NetworkConnector = (*MatrixConnector)(nil)

func (mc *MatrixConnector) GetName() bridgev2.BridgeName {
	return bridgev2.BridgeName{
		DisplayName:          "Matrix",
		NetworkURL:           "https://matrix.org",
		NetworkID:            "matrix",
		BeeperBridgeType:     "matrix",
		DefaultPort:          29341,
		DefaultCommandPrefix: "!matrix",
	}
}

func (mc *MatrixConnector) Init(bridge *bridgev2.Bridge) {
	mc.Bridge = bridge
}

func (mc *MatrixConnector) Start(ctx context.Context) error {
	return nil
}

func (mc *MatrixConnector) GetCapabilities() *bridgev2.NetworkGeneralCapabilities {
	return &bridgev2.NetworkGeneralCapabilities{}
}

func (mc *MatrixConnector) GetBridgeInfoVersion() (info, capabilities int) {
	return 1, 1
}

func (mc *MatrixConnector) GetDBMetaTypes() database.MetaTypes {
	return database.MetaTypes{
		UserLogin: func() any { return &UserLoginMetadata{} },
		Reaction:  func() any { return &ReactionMetadata{} },
	}
}

// UserLoginMetadata is what it takes to resume an outside account.
type UserLoginMetadata struct {
	HomeserverURL string `json:"homeserver_url"`
	AccessToken   string `json:"access_token"`
	DeviceID      string `json:"device_id"`
	// Verified is set once the recovery key has cross-signed this device.
	Verified bool `json:"verified,omitempty"`
}

// ReactionMetadata keeps the outside event ID of a reaction, so a
// redaction there can find it here, and one here can be sent there.
type ReactionMetadata struct {
	EventID string `json:"event_id"`
}
