// Switchboard addition to mautrix-signal. AGPL-3.0-or-later, like the bridge.

package events

import "go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf/signalpb"

func (*CallSignal) isSignalEvent() {}

// CallSignal carries every call message as received, for a client that runs
// RingRTC itself. Call is still sent alongside it for the call notices.
type CallSignal struct {
	Info           MessageInfo
	SenderDeviceID uint32
	Message        *signalpb.CallMessage
}
