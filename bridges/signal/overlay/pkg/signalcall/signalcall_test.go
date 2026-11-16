// Switchboard addition to mautrix-signal. AGPL-3.0-or-later, like the bridge.

package signalcall

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mau.fi/util/ptr"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf/signalpb"
)

func TestRoundTrip(t *testing.T) {
	const id = uint64(18446744073709551615)
	messages := map[string]*signalpb.CallMessage{
		"offer": {Offer: &signalpb.CallMessage_Offer{
			Id:     ptr.Ptr(id),
			Type:   signalpb.CallMessage_Offer_OFFER_VIDEO_CALL.Enum(),
			Opaque: []byte("offer"),
		}},
		"answer": {Answer: &signalpb.CallMessage_Answer{Id: ptr.Ptr(id), Opaque: []byte("answer")}},
		"ice": {IceUpdate: []*signalpb.CallMessage_IceUpdate{
			{Id: ptr.Ptr(id), Opaque: []byte("candidate 1")},
			{Id: ptr.Ptr(id), Opaque: []byte("candidate 2")},
		}},
		"busy": {Busy: &signalpb.CallMessage_Busy{Id: ptr.Ptr(id)}},
		"hangup normal": {Hangup: &signalpb.CallMessage_Hangup{
			Id:   ptr.Ptr(id),
			Type: signalpb.CallMessage_Hangup_HANGUP_NORMAL.Enum(),
		}},
		"hangup accepted on another device": {Hangup: &signalpb.CallMessage_Hangup{
			Id:       ptr.Ptr(id),
			Type:     signalpb.CallMessage_Hangup_HANGUP_ACCEPTED.Enum(),
			DeviceId: ptr.Ptr(uint32(3)),
		}},
		"opaque": {Opaque: &signalpb.CallMessage_Opaque{
			Data:    []byte("group ring"),
			Urgency: signalpb.CallMessage_Opaque_HANDLE_IMMEDIATELY.Enum(),
		}},
	}
	for name, msg := range messages {
		t.Run(name, func(t *testing.T) {
			content := FromSignal(msg)
			require.NotNil(t, content)
			raw, err := json.Marshal(content)
			require.NoError(t, err)
			var parsed Content
			require.NoError(t, json.Unmarshal(raw, &parsed))
			back, err := ToSignal(&parsed)
			require.NoError(t, err)
			assert.True(t, proto.Equal(msg, back), "got %v, want %v", back, msg)
		})
	}
}

func TestCallIDIsAString(t *testing.T) {
	content := FromSignal(&signalpb.CallMessage{Busy: &signalpb.CallMessage_Busy{Id: ptr.Ptr(uint64(18446744073709551615))}})
	raw, err := json.Marshal(content)
	require.NoError(t, err)
	assert.JSONEq(t, `{"kind":"busy","call_id":"18446744073709551615"}`, string(raw))
}

func TestToSignalTargetsOneDevice(t *testing.T) {
	msg, err := ToSignal(&Content{Kind: KindAnswer, CallID: "7", Opaque: []byte("answer"), DestinationDeviceID: ptr.Ptr(uint32(2))})
	require.NoError(t, err)
	assert.Equal(t, uint32(2), msg.GetDestinationDeviceId())
}

func TestToSignalRejectsBadEvents(t *testing.T) {
	for name, content := range map[string]*Content{
		"no call id":    {Kind: KindBusy},
		"bad call id":   {Kind: KindBusy, CallID: "-1"},
		"unknown kind":  {Kind: "ring", CallID: "7"},
		"no candidates": {Kind: KindIce, CallID: "7"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := ToSignal(content)
			assert.Error(t, err)
		})
	}
}

func TestFromSignalIgnoresEmptyMessages(t *testing.T) {
	assert.Nil(t, FromSignal(&signalpb.CallMessage{DestinationDeviceId: ptr.Ptr(uint32(2))}))
}
