// Switchboard addition to mautrix-signal. AGPL-3.0-or-later, like the bridge.

package connector

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
	"go.mau.fi/util/exhttp"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/event"

	"go.mau.fi/mautrix-signal/pkg/libsignalgo"
	"go.mau.fi/mautrix-signal/pkg/signalcall"
	"go.mau.fi/mautrix-signal/pkg/signalid"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/events"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf/signalpb"
)

// handleCallSignal relays a Signal call message into the DM portal for the
// app's RingRTC. Failures are logged and dropped: retrying stale signalling
// would only confuse the call.
func (s *SignalClient) handleCallSignal(evt *events.CallSignal) bool {
	log := s.UserLogin.Log.With().
		Str("action", "relay call signal").
		Stringer("sender", evt.Info.Sender).
		Uint32("sender_device_id", evt.SenderDeviceID).
		Logger()
	ctx := log.WithContext(s.Main.Bridge.BackgroundCtx)
	ownDeviceID := uint32(s.Client.Store.DeviceID)
	// Answers and ICE for a call on the phone come here too.
	if dest := evt.Message.DestinationDeviceId; dest != nil && *dest != ownDeviceID {
		log.Debug().Uint32("destination_device_id", *dest).Msg("Ignoring call message for another device")
		return true
	}
	content := signalcall.FromSignal(evt.Message)
	if content == nil {
		log.Debug().Msg("Ignoring call message with nothing to relay")
		return true
	}
	log = log.With().Str("kind", string(content.Kind)).Str("call_id", content.CallID).Logger()
	content.SenderDeviceID = evt.SenderDeviceID
	content.ReceiverDeviceID = ownDeviceID
	content.ServerTimestamp = evt.Info.ServerTimestamp
	if content.Kind == signalcall.KindOffer || content.Kind == signalcall.KindAnswer {
		var err error
		content.SenderIdentityKey, content.ReceiverIdentityKey, err = s.callIdentityKeys(ctx, evt.Info.Sender)
		if err != nil {
			log.Err(err).Msg("Failed to get identity keys for call message")
			return true
		}
	}
	portal, err := s.Main.Bridge.GetExistingPortalByKey(ctx, s.makePortalKey(evt.Info.ChatID))
	if err != nil {
		log.Err(err).Msg("Failed to get portal for call message")
		return true
	} else if portal == nil || portal.MXID == "" {
		log.Warn().Msg("No portal room to relay call message to")
		return true
	}
	ghost, err := s.Main.Bridge.GetGhostByID(ctx, signalid.MakeUserID(evt.Info.Sender))
	if err != nil {
		log.Err(err).Msg("Failed to get ghost for call message")
		return true
	}
	_, err = ghost.Intent.SendMessage(ctx, portal.MXID, signalcall.EventType, &event.Content{Parsed: content}, nil)
	if err != nil {
		log.Err(err).Msg("Failed to relay call message")
	} else {
		log.Debug().Msg("Relayed call message")
	}
	return true
}

// callIdentityKeys returns the contact's and our ACI identity keys without the
// type byte, the form RingRTC derives the call's SRTP keys from.
func (s *SignalClient) callIdentityKeys(ctx context.Context, contact uuid.UUID) (sender, receiver []byte, err error) {
	theirKey, err := s.Client.Store.IdentityKeyStore.GetIdentityKey(ctx, libsignalgo.NewACIServiceID(contact))
	if err != nil {
		return nil, nil, err
	} else if theirKey == nil {
		return nil, nil, fmt.Errorf("no identity key stored for %s", contact)
	}
	if sender, err = identityKeyBytes(theirKey); err != nil {
		return nil, nil, err
	}
	if receiver, err = identityKeyBytes(s.Client.Store.ACIIdentityKeyPair.GetIdentityKey()); err != nil {
		return nil, nil, err
	}
	return sender, receiver, nil
}

func identityKeyBytes(key *libsignalgo.IdentityKey) ([]byte, error) {
	serialized, err := key.Serialize()
	if err != nil {
		return nil, err
	} else if len(serialized) != 33 {
		return nil, fmt.Errorf("identity key is %d bytes, expected 33", len(serialized))
	}
	return serialized[1:], nil
}

// HandleMatrixCallEvent sends the app's call signalling to the contact on
// Signal. cmd/mautrix-signal registers it on the Matrix event processor.
func (sc *SignalConnector) HandleMatrixCallEvent(ctx context.Context, evt *event.Event) {
	br := sc.Bridge
	if evt.Sender == br.Bot.GetMXID() || br.IsGhostMXID(evt.Sender) {
		return
	}
	log := zerolog.Ctx(ctx).With().
		Str("action", "send call signal").
		Stringer("event_id", evt.ID).
		Stringer("room_id", evt.RoomID).
		Logger()
	ctx = log.WithContext(ctx)
	var content signalcall.Content
	if err := json.Unmarshal(evt.Content.VeryRaw, &content); err != nil {
		log.Warn().Err(err).Msg("Invalid call event")
		return
	}
	log = log.With().Str("kind", string(content.Kind)).Str("call_id", content.CallID).Logger()
	msg, err := signalcall.ToSignal(&content)
	if err != nil {
		log.Warn().Err(err).Msg("Invalid call event")
		return
	}
	user, err := br.GetExistingUserByMXID(ctx, evt.Sender)
	if err != nil {
		log.Err(err).Msg("Failed to get sender of call event")
		return
	} else if user == nil || !user.Permissions.SendEvents {
		log.Warn().Msg("Dropping call event from user without permission")
		return
	}
	portal, err := br.GetPortalByMXID(ctx, evt.RoomID)
	if err != nil {
		log.Err(err).Msg("Failed to get portal for call event")
		return
	} else if portal == nil {
		log.Warn().Msg("Dropping call event outside a portal")
		return
	}
	recipient, _, err := signalid.ParsePortalID(portal.ID)
	if err != nil || recipient.IsEmpty() {
		log.Warn().Err(err).Msg("Dropping call event outside a DM")
		return
	}
	login, _, err := portal.FindPreferredLogin(ctx, user, false)
	if err != nil || login == nil {
		log.Warn().Err(err).Msg("No Signal login for call event")
		return
	}
	client, ok := login.Client.(*SignalClient)
	if !ok || !client.IsLoggedIn() {
		log.Warn().Msg("Signal login isn't connected for call event")
		return
	}
	res := client.Client.SendMessage(ctx, recipient, &signalpb.Content{
		Content: &signalpb.Content_CallMessage{CallMessage: msg},
	})
	if !res.WasSuccessful {
		log.Err(res.Error).Msg("Failed to send call message to Signal")
	} else {
		log.Debug().Msg("Sent call message to Signal")
	}
}

// GetCallsConfig serves GET /v3/calls/config: the bridge's Signal device id,
// which RingRTC needs as the local device, and Signal's TURN servers.
func (sc *SignalConnector) GetCallsConfig(w http.ResponseWriter, r *http.Request, user *bridgev2.User) {
	login := user.GetDefaultLogin()
	if login == nil {
		mautrix.MNotFound.WithMessage("Not logged in to Signal").Write(w)
		return
	}
	client, ok := login.Client.(*SignalClient)
	if !ok || !client.IsLoggedIn() {
		mautrix.MNotFound.WithMessage("Signal login isn't connected").Write(w)
		return
	}
	raw, err := client.Client.GetCallingRelays(r.Context())
	if err != nil {
		zerolog.Ctx(r.Context()).Err(err).Msg("Failed to get TURN servers from Signal")
		mautrix.MUnknown.WithMessage("Failed to get TURN servers from Signal").Write(w)
		return
	}
	var relays struct {
		Relays json.RawMessage `json:"relays"`
	}
	if err = json.Unmarshal(raw, &relays); err != nil {
		zerolog.Ctx(r.Context()).Err(err).Msg("Invalid TURN server response from Signal")
		mautrix.MUnknown.WithMessage("Invalid TURN server response from Signal").Write(w)
		return
	}
	exhttp.WriteJSONResponse(w, http.StatusOK, map[string]any{
		"device_id": client.Client.Store.DeviceID,
		"relays":    relays.Relays,
	})
}
