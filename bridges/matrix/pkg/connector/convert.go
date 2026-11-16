package connector

import (
	"context"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// matrix.to user links, as pills use them, with the user ID URL-encoded
// or not.
var userLinkRe = regexp.MustCompile(`https://matrix\.to/#/(@[^"'<>?\s]+|%40[^"'<>?\s]+)`)

// mapUserLinks rewrites user pills from one side's IDs to the other's.
func mapUserLinks(html string, mapUser func(id.UserID) (id.UserID, bool)) string {
	return userLinkRe.ReplaceAllStringFunc(html, func(link string) string {
		raw := strings.TrimPrefix(link, "https://matrix.to/#/")
		decoded, err := url.PathUnescape(raw)
		if err != nil {
			return link
		}
		mapped, ok := mapUser(id.UserID(decoded))
		if !ok {
			return link
		}
		return "https://matrix.to/#/" + url.PathEscape(mapped.String())
	})
}

// toLocal maps an outside user to who represents them here: the owner for
// the account itself, otherwise their ghost.
func (mc *MatrixClient) toLocal(u id.UserID) (id.UserID, bool) {
	if u == mc.cli.UserID {
		return mc.login.UserMXID, true
	}
	if _, _, err := u.ParseAndValidateRelaxed(); err != nil {
		return "", false
	}
	return mc.main.Bridge.Matrix.FormatGhostMXID(makeUserID(u)), true
}

// toRemote is the reverse: ghosts become the outside users they stand for,
// and the owner becomes the account.
func (mc *MatrixClient) toRemote(u id.UserID) (id.UserID, bool) {
	if u == mc.login.UserMXID {
		return mc.cli.UserID, true
	}
	if ghost, ok := mc.main.Bridge.Matrix.ParseGhostMXID(u); ok {
		return remoteUserID(ghost), true
	}
	return "", false
}

func mapMentions(content *event.MessageEventContent, mapUser func(id.UserID) (id.UserID, bool)) {
	if content.FormattedBody != "" {
		content.FormattedBody = mapUserLinks(content.FormattedBody, mapUser)
	}
	if content.Mentions != nil {
		users := content.Mentions.UserIDs[:0]
		for _, u := range content.Mentions.UserIDs {
			if mapped, ok := mapUser(u); ok {
				users = append(users, mapped)
			}
		}
		content.Mentions.UserIDs = users
	}
}

// cloneContent copies a message's content so changes don't touch the
// original event.
func cloneContent(evt *event.Event) (*event.MessageEventContent, error) {
	if evt.Content.Parsed == nil {
		if err := evt.Content.ParseRaw(evt.Type); err != nil {
			return nil, err
		}
	}
	src := evt.Content.AsMessage()
	dup := *src
	if src.Info != nil {
		info := *src.Info
		dup.Info = &info
	}
	if src.Mentions != nil {
		m := *src.Mentions
		m.UserIDs = append([]id.UserID(nil), src.Mentions.UserIDs...)
		dup.Mentions = &m
	}
	return &dup, nil
}

func (mc *MatrixClient) convertMessage(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, evt *event.Event) (*bridgev2.ConvertedMessage, error) {
	content, err := cloneContent(evt)
	if err != nil {
		return nil, err
	}
	cm := &bridgev2.ConvertedMessage{}
	if rel := content.RelatesTo; rel != nil {
		if reply := rel.GetReplyTo(); reply != "" {
			cm.ReplyTo = &networkid.MessageOptionalPartID{MessageID: makeMessageID(reply)}
		}
		if rel.Type == event.RelThread && rel.EventID != "" {
			cm.ThreadRoot = ptrTo(makeMessageID(rel.EventID))
		}
	}
	content.RelatesTo = nil
	content.RemoveReplyFallback()
	mapMentions(content, mc.toLocal)
	if err = mc.bringMediaIn(ctx, portal, intent, content); err != nil {
		return nil, err
	}
	evtType := event.EventMessage
	if evt.Type == event.EventSticker {
		evtType = event.EventSticker
	}
	cm.Parts = []*bridgev2.ConvertedMessagePart{{Type: evtType, Content: content}}
	return cm, nil
}

func (mc *MatrixClient) convertEdit(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, existing []*database.Message, evt *event.Event) (*bridgev2.ConvertedEdit, error) {
	if len(existing) == 0 {
		return nil, fmt.Errorf("no message to edit")
	}
	msg := evt.Content.AsMessage()
	if msg.NewContent == nil {
		return nil, fmt.Errorf("edit has no new content")
	}
	content := *msg.NewContent
	content.RelatesTo = nil
	mapMentions(&content, mc.toLocal)
	if err := mc.bringMediaIn(ctx, portal, intent, &content); err != nil {
		return nil, err
	}
	return &bridgev2.ConvertedEdit{ModifiedParts: []*bridgev2.ConvertedEditPart{{
		Part:    existing[0],
		Type:    event.EventMessage,
		Content: &content,
	}}}, nil
}

// bringMediaIn downloads an outside attachment (decrypting it if it was
// encrypted) and uploads it to this server. Thumbnails are dropped; the
// app makes its own.
func (mc *MatrixClient) bringMediaIn(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, content *event.MessageEventContent) error {
	if content.URL == "" && content.File == nil {
		return nil
	}
	var data []byte
	var err error
	if content.File != nil {
		uri, perr := content.File.URL.Parse()
		if perr != nil {
			return fmt.Errorf("bad attachment URL: %w", perr)
		}
		if data, err = mc.cli.DownloadBytes(ctx, uri); err == nil {
			err = content.File.DecryptInPlace(data)
		}
	} else {
		uri, perr := content.URL.Parse()
		if perr != nil {
			return fmt.Errorf("bad attachment URL: %w", perr)
		}
		data, err = mc.cli.DownloadBytes(ctx, uri)
	}
	if err != nil {
		return fmt.Errorf("couldn't fetch attachment: %w", err)
	}
	mime := ""
	if content.Info != nil {
		mime = content.Info.MimeType
	}
	mxc, file, err := intent.UploadMedia(ctx, portal.MXID, data, content.GetFileName(), mime)
	if err != nil {
		return fmt.Errorf("couldn't upload attachment: %w", err)
	}
	content.URL, content.File = mxc, file
	if content.Info != nil {
		content.Info.ThumbnailURL = ""
		content.Info.ThumbnailFile = nil
		content.Info.ThumbnailInfo = nil
	}
	return nil
}

func ptrTo[T any](v T) *T { return &v }
