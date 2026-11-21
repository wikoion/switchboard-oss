// Switchboard addition to mautrix-discord. AGPL-3.0-or-later, like the bridge.

// Switchboard: choosing which guild channels bridge, one channel at a time.
//
// Upstream bridges DMs always and guilds whole (or not at all). This adds a
// per-channel choice on top, kept in the login's metadata, and the
// provisioning endpoints Switchboard's Settings screen uses:
//
//	GET    /switchboard/v1/channels                       what the login can see, by guild
//	PUT    /switchboard/v1/channels/{groupID}/{channelID}  start bridging a channel
//	DELETE /switchboard/v1/channels/{groupID}/{channelID}  stop bridging it
//
// All take ?login_id= like the rest of the provisioning API. Deselecting
// keeps the channel's portal and room, so its history stays; the bridge
// just stops passing on what happens there, and work queued while it was
// selected (creating its room, fetching messages) does nothing once it runs.
//
// A channel is offered, and can be selected, only when the login's View
// Channel permission on it was worked out. Upstream's canSeeGuildChannel
// answers yes when it can't tell, which suits a guild somebody chose to
// bridge whole but would offer hidden channels here.

package connector

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"slices"
	"strings"
	"sync"

	"github.com/bwmarrin/discordgo"
	"github.com/rs/zerolog"
	"go.mau.fi/util/exhttp"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"

	"go.mau.fi/mautrix-discord/pkg/discordid"
	"go.mau.fi/mautrix-discord/pkg/router"
)

// switchboardChannelsLock guards every login's SwitchboardChannels. The maps
// are replaced, never changed in place, so a reader holding one stays safe.
var switchboardChannelsLock sync.RWMutex

// Seams for the tests, which run without a database or a gateway.
var (
	saveSwitchboardLogin = func(ctx context.Context, login *bridgev2.UserLogin) error {
		return login.Save(ctx)
	}
	syncSwitchboardGuild = func(d *DiscordClient, guildID string) {
		go func() {
			ctx := d.connector.Bridge.BackgroundCtx
			if err := d.syncGuild(ctx, guildID); err != nil {
				zerolog.Ctx(ctx).Err(err).Str("guild_id", guildID).
					Msg("Failed to sync guild after a channel was selected")
			}
		}()
	}
)

func selectableChannel(ch *discordgo.Channel) bool {
	return ch != nil && ch.GuildID != "" &&
		(ch.Type == discordgo.ChannelTypeGuildText || ch.Type == discordgo.ChannelTypeGuildNews)
}

func (d *DiscordClient) wholeGuildBridged(guildID string) bool {
	_, ok := d.bridgedGuildIDs()[guildID]
	return ok
}

// channelSelected reports whether a guild channel should bridge. A choice
// made for the channel itself wins; without one the channel follows its
// guild, which upstream's guild API or the config file may bridge whole.
func (d *DiscordClient) channelSelected(guildID, channelID string) bool {
	switchboardChannelsLock.RLock()
	choice, chosen := d.userLoginMetadata().SwitchboardChannels[guildID][channelID]
	switchboardChannelsLock.RUnlock()
	if chosen {
		return choice
	}
	return d.wholeGuildBridged(guildID)
}

func (d *DiscordClient) selectedChannelGuildIDs() []string {
	switchboardChannelsLock.RLock()
	defer switchboardChannelsLock.RUnlock()
	var guildIDs []string
	for guildID, channels := range d.userLoginMetadata().SwitchboardChannels {
		for _, selected := range channels {
			if selected {
				guildIDs = append(guildIDs, guildID)
				break
			}
		}
	}
	return guildIDs
}

// guildIDsToSync lists the guilds with anything to bridge: those bridged
// whole and those with a selected channel.
func (d *DiscordClient) guildIDsToSync() []string {
	guildIDs := slices.Collect(maps.Keys(d.bridgedGuildIDs()))
	guildIDs = append(guildIDs, d.selectedChannelGuildIDs()...)
	slices.Sort(guildIDs)
	return slices.Compact(guildIDs)
}

func (d *DiscordClient) guildHasBridgedChannels(guildID string) bool {
	return d.wholeGuildBridged(guildID) || slices.Contains(d.selectedChannelGuildIDs(), guildID)
}

// channelStillBridges reports whether a channel bridges at the moment queued
// work for it runs, which can be well after the work was queued. Only guild
// text channels can have been deselected.
func (d *DiscordClient) channelStillBridges(ch *discordgo.Channel) bool {
	return !selectableChannel(ch) || d.channelSelected(ch.GuildID, ch.ID)
}

// backfillAllowed reports whether messages fetched for a portal may still be
// passed on. DMs always are. A guild channel is only while it is selected,
// so a fetch queued before it was deselected brings nothing in.
func (d *DiscordClient) backfillAllowed(portal *bridgev2.Portal) bool {
	channelID := discordid.ParseChannelPortalID(portal.ID)
	var guildID string
	if meta, _ := portal.Metadata.(*discordid.PortalMetadata); meta != nil {
		guildID = meta.GuildID
	}
	if guildID == "" {
		// A portal that hasn't been told its guild yet: go by the cache.
		if ch, err := d.Session.State.Channel(channelID); err == nil {
			guildID = ch.GuildID
		}
	}
	if guildID == "" {
		return true
	}
	return d.channelSelected(guildID, channelID)
}

// backfillStopped is FetchMessages' answer for a channel that isn't
// selected: no messages. The history queue is told to come back later
// rather than that the channel has no more, so history carries on if the
// channel is selected again.
func backfillStopped(params bridgev2.FetchMessagesParams) *bridgev2.FetchMessagesResponse {
	return &bridgev2.FetchMessagesResponse{
		Forward: params.Forward,
		Pending: !params.Forward && params.ThreadRoot == "",
	}
}

// ownGuildMembership makes sure the login's own membership of a guild, and
// so its roles there, is in the cache, asking Discord when it isn't. Without
// it no channel permission in the guild can be worked out.
func (d *DiscordClient) ownGuildMembership(guildID string) error {
	state := d.Session.State
	if state.User == nil {
		return errors.New("own user is unknown")
	}
	if _, err := state.Member(guildID, state.User.ID); err == nil {
		return nil
	}
	member, err := d.Session.GuildMember(guildID, state.User.ID)
	if err != nil {
		return fmt.Errorf("failed to fetch own membership: %w", err)
	} else if member == nil {
		return errors.New("fetching own membership returned nothing")
	}
	if err = state.MemberAdd(member); err != nil {
		return fmt.Errorf("failed to cache own membership: %w", err)
	}
	return nil
}

// channelVisible reports whether the login has View Channel on a channel
// from the cache. An error means it couldn't be worked out, which callers
// must not take for a yes. ownGuildMembership has to have succeeded first.
func (d *DiscordClient) channelVisible(ch *discordgo.Channel) (bool, error) {
	state := d.Session.State
	if state.User == nil {
		return false, errors.New("own user is unknown")
	}
	perms, err := state.UserChannelPermissions(state.User.ID, ch.ID)
	if err != nil {
		return false, err
	}
	return perms&discordgo.PermissionViewChannel != 0, nil
}

// routeSelected reports whether events routed to a portal should still
// bridge. Only guild text channels can be deselected; DMs, categories and
// channels missing from the cache are left to upstream's checks.
func (d *DiscordClient) routeSelected(ctx context.Context, route *router.Route) bool {
	if route == nil {
		return true
	}
	ch := d.channelWithID(ctx, route.PortalChannelID)
	if !selectableChannel(ch) {
		return true
	}
	return d.channelSelected(ch.GuildID, ch.ID)
}

// setChannelSelected records a choice and saves it. If the save fails the
// choice is undone, so the bridge never acts on a selection it lost.
func (d *DiscordClient) setChannelSelected(ctx context.Context, guildID, channelID string, selected bool) error {
	wholeGuild := d.wholeGuildBridged(guildID)

	switchboardChannelsLock.Lock()
	defer switchboardChannelsLock.Unlock()
	meta := d.userLoginMetadata()
	previous := meta.SwitchboardChannels
	next := make(map[string]map[string]bool, len(previous)+1)
	for id, channels := range previous {
		next[id] = maps.Clone(channels)
	}
	if selected || wholeGuild {
		if next[guildID] == nil {
			next[guildID] = map[string]bool{}
		}
		next[guildID][channelID] = selected
	} else {
		delete(next[guildID], channelID)
		if len(next[guildID]) == 0 {
			delete(next, guildID)
		}
	}
	meta.SwitchboardChannels = next
	if err := saveSwitchboardLogin(ctx, d.UserLogin); err != nil {
		meta.SwitchboardChannels = previous
		return err
	}
	return nil
}

type switchboardChannel struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// The channel's category, when it has one.
	Section  string `json:"section,omitempty"`
	Selected bool   `json:"selected"`
}

type switchboardChannelGroup struct {
	ID       string               `json:"id"`
	Name     string               `json:"name"`
	Channels []switchboardChannel `json:"channels"`
}

type respSwitchboardChannels struct {
	Groups []switchboardChannelGroup `json:"groups"`
}

type respSwitchboardChannel struct {
	GroupID  string `json:"group_id"`
	ID       string `json:"id"`
	Selected bool   `json:"selected"`
}

// switchboardChannelGroups lists the text channels the login can see in each
// of its guilds, in Discord's order: loose channels, then each category's.
func (d *DiscordClient) switchboardChannelGroups(ctx context.Context) []switchboardChannelGroup {
	type guildSnapshot struct {
		id, name string
		channels []*discordgo.Channel
	}
	state := d.Session.State
	state.RLock()
	guilds := make([]guildSnapshot, 0, len(state.Guilds))
	for _, guild := range state.Guilds {
		guilds = append(guilds, guildSnapshot{guild.ID, guild.Name, slices.Clone(guild.Channels)})
	}
	state.RUnlock()
	slices.SortFunc(guilds, func(a, b guildSnapshot) int {
		return cmp.Or(cmp.Compare(strings.ToLower(a.name), strings.ToLower(b.name)), cmp.Compare(a.id, b.id))
	})

	log := zerolog.Ctx(ctx)
	groups := []switchboardChannelGroup{}
	for _, guild := range guilds {
		// One lookup a guild at most, however many channels it has.
		if err := d.ownGuildMembership(guild.id); err != nil {
			log.Warn().Err(err).Str("guild_id", guild.id).
				Msg("Not offering a guild's channels: can't work out which of them the login can see")
			continue
		}
		categories := map[string]*discordgo.Channel{}
		for _, ch := range guild.channels {
			if ch.Type == discordgo.ChannelTypeGuildCategory {
				categories[ch.ID] = ch
			}
		}
		// Loose channels sort ahead of every category.
		categoryPosition := func(ch *discordgo.Channel) int {
			if category := categories[ch.ParentID]; category != nil {
				return category.Position
			}
			return -1
		}
		var visible []*discordgo.Channel
		for _, ch := range guild.channels {
			if !selectableChannel(ch) {
				continue
			}
			if canView, err := d.channelVisible(ch); err != nil {
				log.Warn().Err(err).Str("channel_id", ch.ID).
					Msg("Not offering a channel: can't work out whether the login can see it")
			} else if canView {
				visible = append(visible, ch)
			}
		}
		if len(visible) == 0 {
			continue
		}
		slices.SortFunc(visible, func(a, b *discordgo.Channel) int {
			return cmp.Or(
				cmp.Compare(categoryPosition(a), categoryPosition(b)),
				cmp.Compare(a.ParentID, b.ParentID),
				cmp.Compare(a.Position, b.Position),
				cmp.Compare(a.ID, b.ID),
			)
		})
		group := switchboardChannelGroup{ID: guild.id, Name: guild.name}
		for _, ch := range visible {
			entry := switchboardChannel{ID: ch.ID, Name: ch.Name, Selected: d.channelSelected(guild.id, ch.ID)}
			if category := categories[ch.ParentID]; category != nil {
				entry.Section = category.Name
			}
			group.Channels = append(group.Channels, entry)
		}
		groups = append(groups, group)
	}
	return groups
}

func (p *ProvisioningAPI) registerSwitchboardChannels(r *http.ServeMux) {
	r.HandleFunc("GET /switchboard/v1/channels", p.makeHandler(p.switchboardListChannels, true))
	r.HandleFunc("PUT /switchboard/v1/channels/{groupID}/{channelID}", p.makeHandler(p.switchboardSelectChannel, true))
	// Deselecting only changes what the bridge keeps, so it works while the
	// login is disconnected too.
	r.HandleFunc("DELETE /switchboard/v1/channels/{groupID}/{channelID}", p.makeHandler(p.switchboardDeselectChannel, false))
}

func (p *ProvisioningAPI) switchboardListChannels(w http.ResponseWriter, r *http.Request, _ *bridgev2.UserLogin, client *DiscordClient) {
	exhttp.WriteJSONResponse(w, http.StatusOK, respSwitchboardChannels{
		Groups: client.switchboardChannelGroups(r.Context()),
	})
}

func (p *ProvisioningAPI) switchboardSelectChannel(w http.ResponseWriter, r *http.Request, _ *bridgev2.UserLogin, client *DiscordClient) {
	ctx := r.Context()
	guildID, channelID := r.PathValue("groupID"), r.PathValue("channelID")
	ch := client.channelWithID(ctx, channelID)
	if !selectableChannel(ch) || ch.GuildID != guildID {
		mautrix.MNotFound.WithMessage("This account can't see that channel").Write(w)
		return
	}
	err := client.ownGuildMembership(guildID)
	var canView bool
	if err == nil {
		canView, err = client.channelVisible(ch)
	}
	if err != nil {
		// Not knowing is a failure to report, not a channel to bridge.
		p.log.Err(err).Str("channel_id", channelID).Msg("Failed to check channel visibility before selecting it")
		mautrix.MUnknown.WithMessage("Couldn't check this account's access to that channel: %v", err).
			WithStatus(http.StatusBadGateway).Write(w)
		return
	} else if !canView {
		mautrix.MNotFound.WithMessage("This account can't see that channel").Write(w)
		return
	}
	if err = client.setChannelSelected(ctx, guildID, channelID, true); err != nil {
		p.log.Err(err).Str("channel_id", channelID).Msg("Failed to save channel selection")
		mautrix.MUnknown.WithMessage("Couldn't save the selection: %v", err).Write(w)
		return
	}
	// Creates the guild's space, the channel's category and its room, and
	// fetches what the channel holds. Rooms appear once that finishes.
	syncSwitchboardGuild(client, guildID)
	exhttp.WriteJSONResponse(w, http.StatusOK, respSwitchboardChannel{GroupID: guildID, ID: channelID, Selected: true})
}

func (p *ProvisioningAPI) switchboardDeselectChannel(w http.ResponseWriter, r *http.Request, _ *bridgev2.UserLogin, client *DiscordClient) {
	guildID, channelID := r.PathValue("groupID"), r.PathValue("channelID")
	if err := client.setChannelSelected(r.Context(), guildID, channelID, false); err != nil {
		p.log.Err(err).Str("channel_id", channelID).Msg("Failed to save channel selection")
		mautrix.MUnknown.WithMessage("Couldn't save the selection: %v", err).Write(w)
		return
	}
	exhttp.WriteJSONResponse(w, http.StatusOK, respSwitchboardChannel{GroupID: guildID, ID: channelID, Selected: false})
}
