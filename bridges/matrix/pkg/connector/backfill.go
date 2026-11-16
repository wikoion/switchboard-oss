package connector

import (
	"context"
	"errors"
	"slices"
	"time"

	"github.com/rs/zerolog"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

var _ bridgev2.BackfillingNetworkAPI = (*MatrixClient)(nil)

// FetchMessages fills in what was said since the last bridged message (or
// the latest few, for a new chat), reading back from the room's end.
// Backfilling older history isn't supported.
func (mc *MatrixClient) FetchMessages(ctx context.Context, params bridgev2.FetchMessagesParams) (*bridgev2.FetchMessagesResponse, error) {
	if !params.Forward {
		return nil, errors.New("backward backfill isn't supported")
	}
	log := zerolog.Ctx(ctx)
	room := remoteRoomID(params.Portal.ID)
	var anchor id.EventID
	if params.AnchorMessage != nil {
		anchor = remoteEventID(params.AnchorMessage.ID)
	}
	count := max(params.Count, 1)

	var events []*event.Event
	from := ""
	for pages := 0; len(events) < count*3 && pages < 10; pages++ {
		resp, err := mc.cli.Messages(ctx, room, from, "", mautrix.DirectionBackward, nil, 100)
		if err != nil {
			return nil, err
		}
		reached := false
		for _, evt := range resp.Chunk {
			if evt.ID == anchor || (params.AnchorMessage != nil && !time.UnixMilli(evt.Timestamp).After(params.AnchorMessage.Timestamp)) {
				reached = true
				break
			}
			events = append(events, evt)
		}
		if reached || resp.End == "" || len(resp.Chunk) == 0 {
			break
		}
		from = resp.End
	}
	slices.Reverse(events)

	messages := make([]*bridgev2.BackfillMessage, 0, count)
	index := map[id.EventID]*bridgev2.BackfillMessage{}
	var reactions []*event.Event
	for _, evt := range events {
		// /messages events come unparsed; decryption needs the parsed form.
		_ = evt.Content.ParseRaw(evt.Type)
		if evt.Type == event.EventEncrypted {
			decrypted, err := mc.crypto.Decrypt(ctx, evt)
			if err != nil {
				log.Debug().Err(err).Stringer("event_id", evt.ID).Msg("Couldn't decrypt backfilled event")
				messages = append(messages, mc.backfillMessage(evt, undecryptable()))
				continue
			}
			evt = decrypted
		}
		_ = evt.Content.ParseRaw(evt.Type)
		switch evt.Type {
		case event.EventMessage, event.EventSticker:
			msg := evt.Content.AsMessage()
			if msg.RelatesTo != nil && msg.RelatesTo.Type == event.RelReplace {
				// Edits during the gap: show the latest text.
				if target, ok := index[msg.RelatesTo.EventID]; ok && msg.NewContent != nil {
					edited := *evt
					edited.Content = event.Content{Parsed: &event.MessageEventContent{}}
					*edited.Content.Parsed.(*event.MessageEventContent) = *msg.NewContent
					if cm, err := mc.convertMessage(ctx, params.Portal, params.Portal.Bridge.Bot, &edited); err == nil {
						target.ConvertedMessage.Parts = cm.Parts
					}
				}
				continue
			}
			cm, err := mc.convertMessage(ctx, params.Portal, params.Portal.Bridge.Bot, evt)
			if err != nil {
				log.Warn().Err(err).Stringer("event_id", evt.ID).Msg("Couldn't convert backfilled message")
				continue
			}
			bm := mc.backfillMessage(evt, cm)
			messages = append(messages, bm)
			index[evt.ID] = bm
		case event.EventReaction:
			reactions = append(reactions, evt)
		}
	}
	for _, evt := range reactions {
		rel := evt.Content.AsReaction().RelatesTo
		if target, ok := index[rel.EventID]; ok && rel.Type == event.RelAnnotation {
			target.Reactions = append(target.Reactions, &bridgev2.BackfillReaction{
				Timestamp:  time.UnixMilli(evt.Timestamp),
				Sender:     mc.sender(evt.Sender),
				EmojiID:    networkid.EmojiID(rel.Key),
				Emoji:      rel.Key,
				DBMetadata: &ReactionMetadata{EventID: evt.ID.String()},
			})
		}
	}
	if len(messages) > count {
		messages = messages[len(messages)-count:]
	}
	return &bridgev2.FetchMessagesResponse{
		Messages: messages,
		Forward:  true,
	}, nil
}

func (mc *MatrixClient) backfillMessage(evt *event.Event, cm *bridgev2.ConvertedMessage) *bridgev2.BackfillMessage {
	return &bridgev2.BackfillMessage{
		ConvertedMessage: cm,
		Sender:           mc.sender(evt.Sender),
		ID:               makeMessageID(evt.ID),
		Timestamp:        time.UnixMilli(evt.Timestamp),
		StreamOrder:      evt.Timestamp,
	}
}
