package connector

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/util/ptr"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/simplevent"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func (mc *MatrixClient) registerHandlers() {
	syncer := mc.cli.Syncer.(*mautrix.DefaultSyncer)
	syncer.OnSync(mc.onSync)
	syncer.OnEventType(event.EventMessage, mc.onMessage)
	syncer.OnEventType(event.EventSticker, mc.onMessage)
	syncer.OnEventType(event.EventReaction, mc.onReaction)
	syncer.OnEventType(event.EventRedaction, mc.onRedaction)
	syncer.OnEventType(event.EphemeralEventReceipt, mc.onReceipt)
	syncer.OnEventType(event.EphemeralEventTyping, mc.onTyping)
	syncer.OnEventType(event.StateMember, mc.onMember)
	syncer.OnEventType(event.StateRoomName, mc.onRoomInfo)
	syncer.OnEventType(event.StateRoomAvatar, mc.onRoomInfo)
	syncer.OnEventType(event.StateTopic, mc.onRoomInfo)
	syncer.OnEventType(event.AccountDataDirectChats, mc.onDirect)
	mc.crypto.DecryptErrorCallback = mc.onUndecryptable
}

// initialSync is true while handling the first sync of a login. Its
// timelines aren't bridged event by event: each room is created and
// backfilled instead, which keeps the order right.
func initialSync(ctx context.Context) bool {
	since, _ := ctx.Value(mautrix.SyncTokenContextKey).(string)
	return since == ""
}

func (mc *MatrixClient) onSync(ctx context.Context, resp *mautrix.RespSync, since string) bool {
	mc.noteSpaces(resp)
	if !mc.connected {
		mc.connected = true
		mc.login.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnected})
	}
	if since == "" {
		mc.resyncAll(ctx, resp)
	}
	if mc.main.Config.AutoJoinInvites {
		for room := range resp.Rooms.Invite {
			go mc.join(room)
		}
	}
	return true
}

func (mc *MatrixClient) join(room id.RoomID) {
	ctx := mc.login.Log.With().Stringer("room_id", room).Logger().WithContext(context.Background())
	if _, err := mc.cli.JoinRoomByID(ctx, room); err != nil {
		zerolog.Ctx(ctx).Warn().Err(err).Msg("Couldn't accept invite")
	}
}

// noteSpaces remembers which rooms are spaces, so they aren't bridged as
// chats.
func (mc *MatrixClient) noteSpaces(resp *mautrix.RespSync) {
	mc.stateMu.Lock()
	defer mc.stateMu.Unlock()
	for room, data := range resp.Rooms.Join {
		for _, evts := range [][]*event.Event{data.State.Events, data.Timeline.Events} {
			for _, evt := range evts {
				if evt.Type != event.StateCreate {
					continue
				}
				_ = evt.Content.ParseRaw(evt.Type)
				if c, ok := evt.Content.Parsed.(*event.CreateEventContent); ok && c.Type == event.RoomTypeSpace {
					mc.spaces[room] = true
				}
			}
		}
	}
}

// resyncAll creates a portal for every joined room after the first sync;
// each portal then backfills its recent messages.
func (mc *MatrixClient) resyncAll(ctx context.Context, resp *mautrix.RespSync) {
	for room, data := range resp.Rooms.Join {
		if mc.isSpace(room) {
			continue
		}
		var latest time.Time
		for _, evt := range data.Timeline.Events {
			if ts := time.UnixMilli(evt.Timestamp); ts.After(latest) {
				latest = ts
			}
		}
		mc.login.QueueRemoteEvent(&simplevent.ChatResync{
			EventMeta: simplevent.EventMeta{
				Type:         bridgev2.RemoteEventChatResync,
				PortalKey:    mc.portalKey(room),
				CreatePortal: true,
				LogContext: func(c zerolog.Context) zerolog.Context {
					return c.Stringer("room_id", room)
				},
			},
			GetChatInfoFunc: mc.GetChatInfo,
			LatestMessageTS: latest,
		})
	}
}

// skip drops events not to bridge: the first sync's (backfilled instead),
// spaces', and echoes of what this bridge sent. Only the sending session
// sees a transaction ID, so messages from the account's other apps still
// come through.
func (mc *MatrixClient) skip(ctx context.Context, evt *event.Event) bool {
	if evt.Sender == mc.cli.UserID && evt.Unsigned.TransactionID != "" {
		return true
	}
	return initialSync(ctx) || mc.isSpace(evt.RoomID)
}

func (mc *MatrixClient) meta(evt *event.Event, t bridgev2.RemoteEventType) simplevent.EventMeta {
	return simplevent.EventMeta{
		Type:         t,
		PortalKey:    mc.portalKey(evt.RoomID),
		Sender:       mc.sender(evt.Sender),
		Timestamp:    time.UnixMilli(evt.Timestamp),
		StreamOrder:  evt.Timestamp,
		CreatePortal: t == bridgev2.RemoteEventMessage,
		LogContext: func(c zerolog.Context) zerolog.Context {
			return c.Stringer("room_id", evt.RoomID).Stringer("event_id", evt.ID).Stringer("sender", evt.Sender)
		},
	}
}

func (mc *MatrixClient) onMessage(ctx context.Context, evt *event.Event) {
	if mc.skip(ctx, evt) {
		return
	}
	content := evt.Content.AsMessage()
	if content.RelatesTo != nil && content.RelatesTo.Type == event.RelReplace {
		mc.login.QueueRemoteEvent(&simplevent.Message[*event.Event]{
			EventMeta:       mc.meta(evt, bridgev2.RemoteEventEdit),
			Data:            evt,
			ID:              makeMessageID(evt.ID),
			TargetMessage:   makeMessageID(content.RelatesTo.EventID),
			ConvertEditFunc: mc.convertEdit,
		})
		return
	}
	mc.login.QueueRemoteEvent(&simplevent.Message[*event.Event]{
		EventMeta:          mc.meta(evt, bridgev2.RemoteEventMessage),
		Data:               evt,
		ID:                 makeMessageID(evt.ID),
		ConvertMessageFunc: mc.convertMessage,
	})
}

// onUndecryptable bridges a placeholder for a message whose key never
// arrived, so the chat shows that something was said.
func (mc *MatrixClient) onUndecryptable(evt *event.Event, err error) {
	mc.login.Log.Warn().Err(err).Stringer("event_id", evt.ID).Msg("Couldn't decrypt")
	mc.login.QueueRemoteEvent(&simplevent.Message[*event.Event]{
		EventMeta: mc.meta(evt, bridgev2.RemoteEventMessage),
		Data:      evt,
		ID:        makeMessageID(evt.ID),
		ConvertMessageFunc: func(context.Context, *bridgev2.Portal, bridgev2.MatrixAPI, *event.Event) (*bridgev2.ConvertedMessage, error) {
			return undecryptable(), nil
		},
	})
}

func undecryptable() *bridgev2.ConvertedMessage {
	return &bridgev2.ConvertedMessage{Parts: []*bridgev2.ConvertedMessagePart{{
		Type: event.EventMessage,
		Content: &event.MessageEventContent{
			MsgType: event.MsgNotice,
			Body:    "🔒 This message is encrypted and Switchboard doesn't have its key. Add your recovery key under Accounts to read it.",
		},
	}}}
}

func (mc *MatrixClient) onReaction(ctx context.Context, evt *event.Event) {
	if mc.skip(ctx, evt) {
		return
	}
	rel := evt.Content.AsReaction().RelatesTo
	if rel.Type != event.RelAnnotation || rel.EventID == "" {
		return
	}
	mc.login.QueueRemoteEvent(&simplevent.Reaction{
		EventMeta:      mc.meta(evt, bridgev2.RemoteEventReaction),
		TargetMessage:  makeMessageID(rel.EventID),
		Emoji:          rel.Key,
		EmojiID:        networkid.EmojiID(rel.Key),
		ReactionDBMeta: &ReactionMetadata{EventID: evt.ID.String()},
	})
}

func (mc *MatrixClient) onRedaction(ctx context.Context, evt *event.Event) {
	if mc.skip(ctx, evt) {
		return
	}
	target := evt.Redacts
	if target == "" {
		target = evt.Content.AsRedaction().Redacts
	}
	if target == "" {
		return
	}
	// A redacted reaction is found by its outside event ID, kept in the
	// reaction's metadata; anything else is a message.
	var msgID, emojiID, senderID string
	err := mc.main.Bridge.DB.Database.QueryRow(ctx, `
		SELECT message_id, emoji_id, sender_id FROM reaction
		WHERE bridge_id=$1 AND room_receiver=$2 AND metadata->>'event_id'=$3`,
		mc.main.Bridge.ID, mc.login.ID, target.String(),
	).Scan(&msgID, &emojiID, &senderID)
	if err == nil {
		meta := mc.meta(evt, bridgev2.RemoteEventReactionRemove)
		meta.Sender = mc.sender(remoteUserID(networkid.UserID(senderID)))
		mc.login.QueueRemoteEvent(&simplevent.Reaction{
			EventMeta:     meta,
			TargetMessage: networkid.MessageID(msgID),
			EmojiID:       networkid.EmojiID(emojiID),
		})
		return
	} else if !errors.Is(err, sql.ErrNoRows) {
		zerolog.Ctx(ctx).Err(err).Msg("Couldn't look up redacted reaction")
	}
	mc.login.QueueRemoteEvent(&simplevent.MessageRemove{
		EventMeta:     mc.meta(evt, bridgev2.RemoteEventMessageRemove),
		TargetMessage: makeMessageID(target),
	})
}

func (mc *MatrixClient) onReceipt(ctx context.Context, evt *event.Event) {
	if mc.skip(ctx, evt) {
		return
	}
	content, ok := evt.Content.Parsed.(*event.ReceiptEventContent)
	if !ok {
		return
	}
	for eventID, receipts := range *content {
		for receiptType, users := range receipts {
			if receiptType != event.ReceiptTypeRead && receiptType != event.ReceiptTypeReadPrivate {
				continue
			}
			for user, rr := range users {
				if receiptType == event.ReceiptTypeReadPrivate && user != mc.cli.UserID {
					continue
				}
				mc.login.QueueRemoteEvent(&simplevent.Receipt{
					EventMeta: simplevent.EventMeta{
						Type:      bridgev2.RemoteEventReadReceipt,
						PortalKey: mc.portalKey(evt.RoomID),
						Sender:    mc.sender(user),
						Timestamp: rr.Timestamp,
					},
					LastTarget: makeMessageID(eventID),
				})
			}
		}
	}
}

type typingEvent struct {
	simplevent.EventMeta
	timeout time.Duration
}

var _ bridgev2.RemoteTyping = (*typingEvent)(nil)

func (t *typingEvent) GetTimeout() time.Duration { return t.timeout }

// onTyping turns the room's full list of typers into starts and stops.
func (mc *MatrixClient) onTyping(ctx context.Context, evt *event.Event) {
	if mc.skip(ctx, evt) {
		return
	}
	content, ok := evt.Content.Parsed.(*event.TypingEventContent)
	if !ok {
		return
	}
	now := map[id.UserID]bool{}
	for _, u := range content.UserIDs {
		if u != mc.cli.UserID {
			now[u] = true
		}
	}
	mc.stateMu.Lock()
	before := mc.typing[evt.RoomID]
	mc.typing[evt.RoomID] = now
	mc.stateMu.Unlock()
	send := func(u id.UserID, timeout time.Duration) {
		mc.login.QueueRemoteEvent(&typingEvent{
			EventMeta: simplevent.EventMeta{
				Type:      bridgev2.RemoteEventTyping,
				PortalKey: mc.portalKey(evt.RoomID),
				Sender:    mc.sender(u),
			},
			timeout: timeout,
		})
	}
	for u := range now {
		if !before[u] {
			send(u, 30*time.Second)
		}
	}
	for u := range before {
		if !now[u] {
			send(u, 0)
		}
	}
}

func (mc *MatrixClient) onMember(ctx context.Context, evt *event.Event) {
	if evt.StateKey == nil || mc.skip(ctx, evt) {
		return
	}
	user := id.UserID(*evt.StateKey)
	content := evt.Content.AsMember()
	if user == mc.cli.UserID {
		// Our own joins and leaves are handled through sync's room lists.
		return
	}
	member := bridgev2.ChatMember{
		EventSender: mc.sender(user),
		Membership:  content.Membership,
		UserInfo:    mc.memberInfo(user, content),
	}
	mc.login.QueueRemoteEvent(&simplevent.ChatInfoChange{
		EventMeta: mc.meta(evt, bridgev2.RemoteEventChatInfoChange),
		ChatInfoChange: &bridgev2.ChatInfoChange{
			MemberChanges: &bridgev2.ChatMemberList{
				MemberMap: bridgev2.ChatMemberMap{makeUserID(user): member},
			},
		},
	})
}

func (mc *MatrixClient) onRoomInfo(ctx context.Context, evt *event.Event) {
	if mc.skip(ctx, evt) {
		return
	}
	info := &bridgev2.ChatInfo{}
	switch evt.Type {
	case event.StateRoomName:
		info.Name = ptr.Ptr(evt.Content.AsRoomName().Name)
	case event.StateTopic:
		info.Topic = ptr.Ptr(evt.Content.AsTopic().Topic)
	case event.StateRoomAvatar:
		info.Avatar = mc.avatar(evt.Content.AsRoomAvatar().URL)
	}
	mc.login.QueueRemoteEvent(&simplevent.ChatInfoChange{
		EventMeta:      mc.meta(evt, bridgev2.RemoteEventChatInfoChange),
		ChatInfoChange: &bridgev2.ChatInfoChange{ChatInfo: info},
	})
}

func (mc *MatrixClient) onDirect(ctx context.Context, evt *event.Event) {
	if content, ok := evt.Content.Parsed.(*event.DirectChatsEventContent); ok {
		mc.setDirect(*content)
	}
}
