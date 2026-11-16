package connector

import (
	"context"
	"fmt"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/crypto/attachment"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

var (
	_ bridgev2.EditHandlingNetworkAPI        = (*MatrixClient)(nil)
	_ bridgev2.RedactionHandlingNetworkAPI   = (*MatrixClient)(nil)
	_ bridgev2.ReactionHandlingNetworkAPI    = (*MatrixClient)(nil)
	_ bridgev2.ReadReceiptHandlingNetworkAPI = (*MatrixClient)(nil)
	_ bridgev2.TypingHandlingNetworkAPI      = (*MatrixClient)(nil)
)

func txnID(evt *event.Event) string {
	if evt == nil {
		return ""
	}
	return "sb-" + evt.ID.String()
}

func (mc *MatrixClient) HandleMatrixMessage(ctx context.Context, msg *bridgev2.MatrixMessage) (*bridgev2.MatrixMessageResponse, error) {
	room := remoteRoomID(msg.Portal.ID)
	dup := *msg.Content
	content := &dup
	content.RelatesTo = nil
	if msg.ThreadRoot != nil {
		content.RelatesTo = (&event.RelatesTo{}).SetThread(remoteEventID(msg.ThreadRoot.ID), "")
	}
	if msg.ReplyTo != nil {
		if content.RelatesTo == nil {
			content.RelatesTo = &event.RelatesTo{}
		}
		content.RelatesTo.SetReplyTo(remoteEventID(msg.ReplyTo.ID))
	}
	if content.Mentions != nil {
		m := *content.Mentions
		m.UserIDs = append([]id.UserID(nil), content.Mentions.UserIDs...)
		content.Mentions = &m
	}
	mapMentions(content, mc.toRemote)
	if err := mc.sendMediaOut(ctx, room, msg.Portal, content); err != nil {
		return nil, err
	}
	evtType := event.EventMessage
	if msg.Event != nil && msg.Event.Type == event.EventSticker {
		evtType = event.EventSticker
	}
	resp, err := mc.cli.SendMessageEvent(ctx, room, evtType, content, mautrix.ReqSendEvent{TransactionID: txnID(msg.Event)})
	if err != nil {
		return nil, err
	}
	return &bridgev2.MatrixMessageResponse{
		DB: &database.Message{
			ID:        makeMessageID(resp.EventID),
			SenderID:  makeUserID(mc.cli.UserID),
			Timestamp: time.Now(),
		},
	}, nil
}

// sendMediaOut moves an attachment from this server to the outside one,
// encrypting it there when the room is encrypted.
func (mc *MatrixClient) sendMediaOut(ctx context.Context, room id.RoomID, portal *bridgev2.Portal, content *event.MessageEventContent) error {
	if content.URL == "" && content.File == nil {
		return nil
	}
	var data []byte
	var err error
	if content.File != nil {
		data, err = portal.Bridge.Bot.DownloadMedia(ctx, content.File.URL, content.File)
	} else {
		data, err = portal.Bridge.Bot.DownloadMedia(ctx, content.URL, nil)
	}
	if err != nil {
		return fmt.Errorf("couldn't read attachment: %w", err)
	}
	if content.Info != nil {
		info := *content.Info
		info.ThumbnailURL, info.ThumbnailFile, info.ThumbnailInfo = "", nil, nil
		content.Info = &info
	}
	encrypted, _ := mc.cli.StateStore.IsEncrypted(ctx, room)
	mime := "application/octet-stream"
	if content.Info != nil && content.Info.MimeType != "" {
		mime = content.Info.MimeType
	}
	if encrypted {
		file := attachment.NewEncryptedFile()
		file.EncryptInPlace(data)
		up, err := mc.cli.UploadBytesWithName(ctx, data, "application/octet-stream", "")
		if err != nil {
			return fmt.Errorf("couldn't upload attachment: %w", err)
		}
		content.URL = ""
		content.File = &event.EncryptedFileInfo{EncryptedFile: *file, URL: up.ContentURI.CUString()}
		return nil
	}
	up, err := mc.cli.UploadBytesWithName(ctx, data, mime, content.GetFileName())
	if err != nil {
		return fmt.Errorf("couldn't upload attachment: %w", err)
	}
	content.URL, content.File = up.ContentURI.CUString(), nil
	return nil
}

func (mc *MatrixClient) HandleMatrixEdit(ctx context.Context, msg *bridgev2.MatrixEdit) error {
	room := remoteRoomID(msg.Portal.ID)
	dup := *msg.Content
	content := &dup
	content.RelatesTo = nil
	content.NewContent = nil
	mapMentions(content, mc.toRemote)
	content.SetEdit(remoteEventID(msg.EditTarget.ID))
	_, err := mc.cli.SendMessageEvent(ctx, room, event.EventMessage, content, mautrix.ReqSendEvent{TransactionID: txnID(msg.Event)})
	return err
}

func (mc *MatrixClient) HandleMatrixMessageRemove(ctx context.Context, msg *bridgev2.MatrixMessageRemove) error {
	_, err := mc.cli.RedactEvent(ctx, remoteRoomID(msg.Portal.ID), remoteEventID(msg.TargetMessage.ID))
	return err
}

func (mc *MatrixClient) PreHandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (bridgev2.MatrixReactionPreResponse, error) {
	key := msg.Content.RelatesTo.Key
	return bridgev2.MatrixReactionPreResponse{
		SenderID: makeUserID(mc.cli.UserID),
		EmojiID:  networkid.EmojiID(key),
		Emoji:    key,
	}, nil
}

func (mc *MatrixClient) HandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (*database.Reaction, error) {
	resp, err := mc.cli.SendReaction(ctx, remoteRoomID(msg.Portal.ID), remoteEventID(msg.TargetMessage.ID), msg.Content.RelatesTo.Key)
	if err != nil {
		return nil, err
	}
	return &database.Reaction{Metadata: &ReactionMetadata{EventID: resp.EventID.String()}}, nil
}

func (mc *MatrixClient) HandleMatrixReactionRemove(ctx context.Context, msg *bridgev2.MatrixReactionRemove) error {
	meta, ok := msg.TargetReaction.Metadata.(*ReactionMetadata)
	if !ok || meta.EventID == "" {
		return fmt.Errorf("don't know the outside reaction to remove")
	}
	_, err := mc.cli.RedactEvent(ctx, remoteRoomID(msg.Portal.ID), id.EventID(meta.EventID))
	return err
}

func (mc *MatrixClient) HandleMatrixReadReceipt(ctx context.Context, msg *bridgev2.MatrixReadReceipt) error {
	target := msg.ExactMessage
	if target == nil {
		var err error
		target, err = mc.main.Bridge.DB.Message.GetLastPartAtOrBeforeTime(ctx, msg.Portal.PortalKey, msg.ReadUpTo)
		if err != nil || target == nil {
			return err
		}
	}
	return mc.cli.SendReceipt(ctx, remoteRoomID(msg.Portal.ID), remoteEventID(target.ID), event.ReceiptTypeRead, nil)
}

func (mc *MatrixClient) HandleMatrixTyping(ctx context.Context, msg *bridgev2.MatrixTyping) error {
	_, err := mc.cli.UserTyping(ctx, remoteRoomID(msg.Portal.ID), msg.IsTyping, 30*time.Second)
	return err
}

var roomCaps = &event.RoomFeatures{
	ID: "app.switchboard.matrix.capabilities.2026_10_31",
	Formatting: event.FormattingFeatureMap{
		event.FmtBold:          event.CapLevelFullySupported,
		event.FmtItalic:        event.CapLevelFullySupported,
		event.FmtStrikethrough: event.CapLevelFullySupported,
		event.FmtInlineCode:    event.CapLevelFullySupported,
		event.FmtCodeBlock:     event.CapLevelFullySupported,
		event.FmtBlockquote:    event.CapLevelFullySupported,
		event.FmtInlineLink:    event.CapLevelFullySupported,
		event.FmtUserLink:      event.CapLevelFullySupported,
		event.FmtUnorderedList: event.CapLevelFullySupported,
		event.FmtOrderedList:   event.CapLevelFullySupported,
		event.FmtHeaders:       event.CapLevelFullySupported,
		event.FmtSpoiler:       event.CapLevelFullySupported,
	},
	File: event.FileFeatureMap{
		event.MsgImage:      {MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported}, Caption: event.CapLevelFullySupported},
		event.MsgVideo:      {MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported}, Caption: event.CapLevelFullySupported},
		event.MsgAudio:      {MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported}, Caption: event.CapLevelFullySupported},
		event.MsgFile:       {MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported}, Caption: event.CapLevelFullySupported},
		event.CapMsgVoice:   {MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported}},
		event.CapMsgSticker: {MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported}},
	},
	Thread:              event.CapLevelFullySupported,
	Reply:               event.CapLevelFullySupported,
	Edit:                event.CapLevelFullySupported,
	Delete:              event.CapLevelFullySupported,
	Reaction:            event.CapLevelFullySupported,
	ReadReceipts:        true,
	TypingNotifications: true,
}

func (mc *MatrixClient) GetCapabilities(ctx context.Context, portal *bridgev2.Portal) *event.RoomFeatures {
	return roomCaps
}
