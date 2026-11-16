package connector

import (
	_ "embed"

	up "go.mau.fi/util/configupgrade"
)

//go:embed example-config.yaml
var ExampleConfig string

type Config struct {
	// Encrypts the outside accounts' end-to-end keys at rest.
	PickleKey string `yaml:"pickle_key"`
	// The device name the outside accounts see for this bridge.
	DeviceName string `yaml:"device_name"`
	// Most members to bring into a portal; huge public rooms stop here.
	MaxMembers int `yaml:"max_members"`
	// Join rooms the outside account is invited to, so new chats arrive.
	AutoJoinInvites bool `yaml:"auto_join_invites"`
}

func upgradeConfig(helper up.Helper) {
	helper.Copy(up.Str, "pickle_key")
	helper.Copy(up.Str, "device_name")
	helper.Copy(up.Int, "max_members")
	helper.Copy(up.Bool, "auto_join_invites")
}

func (mc *MatrixConnector) GetConfig() (example string, data any, upgrader up.Upgrader) {
	return ExampleConfig, &mc.Config, &up.StructUpgrader{
		SimpleUpgrader: up.SimpleUpgrader(upgradeConfig),
		Base:           ExampleConfig,
	}
}
