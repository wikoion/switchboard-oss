// Switchboard addition to mautrix-signal. AGPL-3.0-or-later, like the bridge.

// Package signalcall converts Signal call messages to and from the Matrix
// events that carry them between the bridge and the Switchboard app. The app
// runs RingRTC itself, so the bridge only relays signalling, never media.
package signalcall

import (
	"fmt"
	"strconv"

	"maunium.net/go/mautrix/event"

	"go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf/signalpb"
)

// EventType is a room event in the DM portal. Sent by the contact's ghost, it
// came from Signal. Sent by the user, it goes to Signal.
var EventType = event.Type{Type: "app.switchboard.signal.call", Class: event.MessageEventType}

type Kind string

const (
	KindOffer  Kind = "offer"
	KindAnswer Kind = "answer"
	KindIce    Kind = "ice"
	KindBusy   Kind = "busy"
	KindHangup Kind = "hangup"
	KindOpaque Kind = "opaque"
)

// Content is the event content. The enum numbers are CallMessage's in
// SignalService.proto, which are also RingRTC's.
type Content struct {
	Kind Kind `json:"kind"`
	// CallID is a decimal string: Matrix JSON can't hold every uint64.
	// Opaque messages have none.
	CallID string `json:"call_id,omitempty"`

	// Set on events from Signal. The identity keys are only on offers and
	// answers, 32 bytes without the type byte.
	SenderDeviceID      uint32 `json:"sender_device_id,omitempty"`
	ReceiverDeviceID    uint32 `json:"receiver_device_id,omitempty"`
	ServerTimestamp     uint64 `json:"server_ts,omitempty"`
	SenderIdentityKey   []byte `json:"sender_identity_key,omitempty"`
	ReceiverIdentityKey []byte `json:"receiver_identity_key,omitempty"`

	// Set on events to Signal meant for one of the contact's devices.
	DestinationDeviceID *uint32 `json:"destination_device_id,omitempty"`

	OfferType      int32    `json:"offer_type,omitempty"`
	HangupType     int32    `json:"hangup_type,omitempty"`
	HangupDeviceID *uint32  `json:"hangup_device_id,omitempty"`
	Opaque         []byte   `json:"opaque,omitempty"`
	Candidates     [][]byte `json:"candidates,omitempty"`
	Urgency        int32    `json:"urgency,omitempty"`
}

// FromSignal converts the signalling part of a call message. The caller fills
// in the device ids, timestamp and identity keys. It returns nil for a message
// with nothing in it.
func FromSignal(msg *signalpb.CallMessage) *Content {
	switch {
	case msg.GetOffer() != nil:
		return &Content{
			Kind:      KindOffer,
			CallID:    formatID(msg.Offer.Id),
			OfferType: int32(msg.Offer.GetType()),
			Opaque:    msg.Offer.Opaque,
		}
	case msg.GetAnswer() != nil:
		return &Content{Kind: KindAnswer, CallID: formatID(msg.Answer.Id), Opaque: msg.Answer.Opaque}
	case len(msg.GetIceUpdate()) > 0:
		content := &Content{Kind: KindIce, CallID: formatID(msg.IceUpdate[0].Id)}
		for _, update := range msg.IceUpdate {
			content.Candidates = append(content.Candidates, update.Opaque)
		}
		return content
	case msg.GetBusy() != nil:
		return &Content{Kind: KindBusy, CallID: formatID(msg.Busy.Id)}
	case msg.GetHangup() != nil:
		return &Content{
			Kind:           KindHangup,
			CallID:         formatID(msg.Hangup.Id),
			HangupType:     int32(msg.Hangup.GetType()),
			HangupDeviceID: msg.Hangup.DeviceId,
		}
	case msg.GetOpaque() != nil:
		return &Content{Kind: KindOpaque, Opaque: msg.Opaque.Data, Urgency: int32(msg.Opaque.GetUrgency())}
	}
	return nil
}

// ToSignal builds the call message for an event from the app.
func ToSignal(content *Content) (*signalpb.CallMessage, error) {
	msg := &signalpb.CallMessage{DestinationDeviceId: content.DestinationDeviceID}
	var callID *uint64
	if content.Kind != KindOpaque {
		id, err := strconv.ParseUint(content.CallID, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid call_id %q: %w", content.CallID, err)
		}
		callID = &id
	}
	switch content.Kind {
	case KindOffer:
		msg.Offer = &signalpb.CallMessage_Offer{
			Id:     callID,
			Type:   signalpb.CallMessage_Offer_Type(content.OfferType).Enum(),
			Opaque: content.Opaque,
		}
	case KindAnswer:
		msg.Answer = &signalpb.CallMessage_Answer{Id: callID, Opaque: content.Opaque}
	case KindIce:
		if len(content.Candidates) == 0 {
			return nil, fmt.Errorf("ice event has no candidates")
		}
		for _, candidate := range content.Candidates {
			msg.IceUpdate = append(msg.IceUpdate, &signalpb.CallMessage_IceUpdate{Id: callID, Opaque: candidate})
		}
	case KindBusy:
		msg.Busy = &signalpb.CallMessage_Busy{Id: callID}
	case KindHangup:
		msg.Hangup = &signalpb.CallMessage_Hangup{
			Id:       callID,
			Type:     signalpb.CallMessage_Hangup_Type(content.HangupType).Enum(),
			DeviceId: content.HangupDeviceID,
		}
	case KindOpaque:
		msg.Opaque = &signalpb.CallMessage_Opaque{
			Data:    content.Opaque,
			Urgency: signalpb.CallMessage_Opaque_Urgency(content.Urgency).Enum(),
		}
	default:
		return nil, fmt.Errorf("unknown call event kind %q", content.Kind)
	}
	return msg, nil
}

func formatID(id *uint64) string {
	if id == nil {
		return ""
	}
	return strconv.FormatUint(*id, 10)
}
