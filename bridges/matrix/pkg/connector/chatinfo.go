package connector

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"go.mau.fi/util/ptr"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// GetChatInfo reads the outside room's state: name, topic, picture and
// members, and whether the account's m.direct marks it as a DM.
func (mc *MatrixClient) GetChatInfo(ctx context.Context, portal *bridgev2.Portal) (*bridgev2.ChatInfo, error) {
	room := remoteRoomID(portal.ID)
	state, err := mc.cli.State(ctx, room)
	if err != nil {
		return nil, fmt.Errorf("couldn't read room state: %w", err)
	}
	get := func(t event.Type) *event.Event {
		evt := state[t][""]
		if evt != nil {
			_ = evt.Content.ParseRaw(evt.Type)
		}
		return evt
	}
	info := &bridgev2.ChatInfo{CanBackfill: true}
	var name string
	if evt := get(event.StateRoomName); evt != nil {
		name = evt.Content.AsRoomName().Name
	}
	if evt := get(event.StateTopic); evt != nil {
		info.Topic = ptr.Ptr(evt.Content.AsTopic().Topic)
	}
	if evt := get(event.StateRoomAvatar); evt != nil {
		info.Avatar = mc.avatar(evt.Content.AsRoomAvatar().URL)
	}

	members := &bridgev2.ChatMemberList{MemberMap: bridgev2.ChatMemberMap{}, IsFull: true}
	var others []string
	ids := make([]string, 0, len(state[event.StateMember]))
	for key := range state[event.StateMember] {
		ids = append(ids, key)
	}
	sort.Strings(ids)
	for _, key := range ids {
		evt := state[event.StateMember][key]
		_ = evt.Content.ParseRaw(evt.Type)
		content := evt.Content.AsMember()
		if content.Membership != event.MembershipJoin && content.Membership != event.MembershipInvite {
			continue
		}
		user := id.UserID(key)
		members.TotalMemberCount++
		if user != mc.cli.UserID {
			others = append(others, displayName(user, content))
			if len(members.MemberMap) >= mc.main.Config.MaxMembers {
				members.IsFull = false
				continue
			}
		}
		members.MemberMap[makeUserID(user)] = bridgev2.ChatMember{
			EventSender: mc.sender(user),
			Membership:  content.Membership,
			UserInfo:    mc.memberInfo(user, content),
		}
	}
	info.Members = members

	partner, isDM := mc.dmPartner(room)
	if !isDM && name == "" && members.TotalMemberCount == 2 && len(others) == 1 {
		for uid := range members.MemberMap {
			if remoteUserID(uid) != mc.cli.UserID {
				partner, isDM = remoteUserID(uid), true
			}
		}
	}
	if isDM {
		info.Type = ptr.Ptr(database.RoomTypeDM)
		members.OtherUserID = makeUserID(partner)
	} else {
		info.Type = ptr.Ptr(database.RoomTypeDefault)
		if name == "" {
			if evt := get(event.StateCanonicalAlias); evt != nil {
				name = evt.Content.AsCanonicalAlias().Alias.String()
			}
		}
		if name == "" {
			name = heroName(others)
		}
	}
	if name != "" {
		info.Name = &name
	}
	return info, nil
}

// heroName names a room without a name after its members, like clients do.
func heroName(others []string) string {
	switch len(others) {
	case 0:
		return ""
	case 1, 2, 3:
		return strings.Join(others, ", ")
	default:
		return fmt.Sprintf("%s and %d others", strings.Join(others[:2], ", "), len(others)-2)
	}
}

func displayName(user id.UserID, content *event.MemberEventContent) string {
	if content != nil && content.Displayname != "" {
		return content.Displayname
	}
	return user.Localpart()
}

func (mc *MatrixClient) memberInfo(user id.UserID, content *event.MemberEventContent) *bridgev2.UserInfo {
	info := &bridgev2.UserInfo{
		Identifiers: []string{"matrix:" + user.String()},
		Name:        ptr.Ptr(displayName(user, content)),
	}
	if content != nil {
		info.Avatar = mc.avatar(content.AvatarURL)
	}
	return info
}

func (mc *MatrixClient) GetUserInfo(ctx context.Context, ghost *bridgev2.Ghost) (*bridgev2.UserInfo, error) {
	user := remoteUserID(ghost.ID)
	profile, err := mc.cli.GetProfile(ctx, user)
	if err != nil {
		return nil, err
	}
	return &bridgev2.UserInfo{
		Identifiers: []string{"matrix:" + user.String()},
		Name:        ptr.Ptr(displayName(user, &event.MemberEventContent{Displayname: profile.DisplayName})),
		Avatar:      mc.avatar(profile.AvatarURL.CUString()),
	}, nil
}

// avatar brings an outside picture across, downloading it when the bridge
// asks.
func (mc *MatrixClient) avatar(uri id.ContentURIString) *bridgev2.Avatar {
	if uri == "" {
		return &bridgev2.Avatar{Remove: true}
	}
	parsed, err := uri.Parse()
	if err != nil {
		return &bridgev2.Avatar{Remove: true}
	}
	return &bridgev2.Avatar{
		ID: networkid.AvatarID(uri),
		Get: func(ctx context.Context) ([]byte, error) {
			return mc.cli.DownloadBytes(ctx, parsed)
		},
	}
}
