// Switchboard addition to mautrix-slack. AGPL-3.0-or-later, like the bridge.

// Switchboard: choosing which Slack channels bridge, one channel at a time.
//
// Upstream either bridges every channel the account is in or, with dm_only,
// none of them. This adds a per-channel choice on top of dm_only, kept in
// the login's metadata, and the provisioning endpoints Switchboard's
// Settings screen uses:
//
//	GET    /switchboard/v1/channels                       the channels the account is in
//	PUT    /switchboard/v1/channels/{groupID}/{channelID}  start bridging a channel
//	DELETE /switchboard/v1/channels/{groupID}/{channelID}  stop bridging it
//
// All take ?login_id= like the rest of the provisioning API; the group is
// the workspace. Deselecting keeps the channel's portal and room, so its
// history stays; the bridge just stops passing on what happens there, and
// work queued while it was selected (creating its room, fetching messages)
// does nothing once it runs.
//
// The first time a login connects with dm_only on, the channels it already
// bridges become its selection, so switching dm_only on changes nothing by
// itself. Without dm_only every channel bridges and none can be deselected.

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
	"time"

	"github.com/rs/zerolog"
	"github.com/slack-go/slack"
	"go.mau.fi/util/exhttp"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/matrix"

	"go.mau.fi/mautrix-slack/pkg/slackid"
)

// switchboardChannelsLock guards every login's SwitchboardChannels. The maps
// are replaced, never changed in place, so a reader holding one stays safe.
var switchboardChannelsLock sync.RWMutex

var errSwitchboardEveryChannelBridged = mautrix.RespError{
	ErrCode:    "SWITCHBOARD_EVERY_CHANNEL_BRIDGED",
	Err:        "This bridge is set to bridge every channel, so channels can't be turned off one by one (set network.dm_only)",
	StatusCode: http.StatusConflict,
}

// Seams for the tests, which run without a database or Slack.
var (
	saveSwitchboardLogin = func(ctx context.Context, login *bridgev2.UserLogin) error {
		return login.Save(ctx)
	}
	// fetchSwitchboardChannel looks one channel up for the resync on
	// connect, through the bridge's cache. Saving a selection asks Slack
	// instead: see fetchChatInfoFresh.
	fetchSwitchboardChannel = func(ctx context.Context, s *SlackClient, channelID string) (*slack.Channel, error) {
		return s.fetchChatInfoWithCache(ctx, channelID, false)
	}
	// listSwitchboardChannels fetches the channels the account is a member
	// of, which are the ones Slack sends it messages for.
	listSwitchboardChannels = func(ctx context.Context, s *SlackClient) ([]slack.Channel, error) {
		var channels []slack.Channel
		cursor := ""
		for page := 0; page < maxSlackPaginationPages; page++ {
			chunk, nextCursor, err := s.Client.GetConversationsForUserContext(ctx, &slack.GetConversationsForUserParameters{
				Types:           []string{"public_channel", "private_channel"},
				Limit:           slackPageLimit(true, 0),
				Cursor:          cursor,
				ExcludeArchived: true,
			})
			if err != nil {
				return nil, err
			}
			channels = append(channels, chunk...)
			if nextCursor == "" {
				return channels, nil
			}
			cursor = nextCursor
		}
		return nil, fmt.Errorf("conversation pagination exceeded %d pages", maxSlackPaginationPages)
	}
	// bridgedSwitchboardChannelIDs lists the channels (not DMs) the login
	// already has rooms for.
	bridgedSwitchboardChannelIDs = func(ctx context.Context, s *SlackClient) ([]string, error) {
		userPortals, err := s.UserLogin.Bridge.DB.UserPortal.GetAllForLogin(ctx, s.UserLogin.UserLogin)
		if err != nil {
			return nil, err
		}
		var channelIDs []string
		for _, up := range userPortals {
			teamID, channelID := slackid.ParsePortalID(up.Portal.ID)
			if channelID == "" || teamID != s.TeamID {
				continue
			}
			portal, err := s.UserLogin.Bridge.GetExistingPortalByKey(ctx, up.Portal)
			if err != nil {
				return nil, err
			}
			if portal == nil || portal.MXID == "" || portal.RoomType != database.RoomTypeDefault {
				continue
			}
			channelIDs = append(channelIDs, channelID)
		}
		return channelIDs, nil
	}
	// syncSwitchboardChannel queues the resync that creates a newly selected
	// channel's room, or catches an existing one up.
	syncSwitchboardChannel = func(s *SlackClient, info *slack.Channel) {
		s.Main.br.QueueRemoteEvent(s.UserLogin, s.newSwitchboardResync(info, s.Main.br.Config.SplitPortals))
	}
)

func (s *SlackClient) newSwitchboardResync(info *slack.Channel, splitPortals bool) *SlackChatResync {
	var latestMessageID string
	if info.Latest != nil {
		latestMessageID = info.Latest.Timestamp
	}
	portalKey := slackid.MakePortalKey(s.TeamID, info.ID, s.UserLogin.ID, splitPortals || info.IsIM || info.IsMpIM)
	return &SlackChatResync{
		SlackEventMeta: &SlackEventMeta{
			Type:         bridgev2.RemoteEventChatResync,
			PortalKey:    portalKey,
			CreatePortal: true,
			LogContext: func(c zerolog.Context) zerolog.Context {
				return c.Object("portal_key", portalKey).Str("slack_latest_message_id", latestMessageID)
			},
		},
		Client:         s,
		LatestMessage:  latestMessageID,
		PreFetchedInfo: info,
	}
}

// fetchChatInfoFresh asks Slack for a channel as the account sees it now.
// The bridge's cache keeps an answer for an hour, in which the account may
// have joined or left the channel, so a selection is never decided from it.
// The answer replaces what the cache held.
func (s *SlackClient) fetchChatInfoFresh(ctx context.Context, channelID string) (*slack.Channel, error) {
	s.chatInfoCacheLock.Lock()
	defer s.chatInfoCacheLock.Unlock()
	info, err := s.Client.GetConversationInfoContext(ctx, &slack.GetConversationInfoInput{
		ChannelID:         channelID,
		IncludeLocale:     true,
		IncludeNumMembers: true,
	})
	s.chatInfoFetchAttempted[channelID] = true
	if err != nil {
		return nil, err
	}
	s.chatInfoCache[channelID] = chatInfoCacheEntry{ts: time.Now(), data: info}
	return info, nil
}

// slackSaysNoSuchChannel reports whether Slack answered that the channel
// doesn't exist for this account, as opposed to not answering.
func slackSaysNoSuchChannel(err error) bool {
	var slackErr slack.SlackErrorResponse
	return errors.As(err, &slackErr) && slackErr.Err == "channel_not_found"
}

// backfillAllowed reports whether messages fetched for a portal may still be
// passed on. DMs and group DMs always are. A channel is only while it is
// selected, so a fetch queued before it was deselected brings nothing in.
func (s *SlackClient) backfillAllowed(portal *bridgev2.Portal, channelID string) bool {
	if portal != nil && (portal.RoomType == database.RoomTypeDM || portal.RoomType == database.RoomTypeGroupDM) {
		return true
	}
	return s.isDMChannel(channelID)
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

// stillBridges reports whether the resync's channel bridges at the moment
// the resync runs, which can be well after it was queued.
func (s *SlackChatResync) stillBridges() bool {
	if info := s.PreFetchedInfo; info != nil && (info.IsIM || info.IsMpIM) {
		return true
	}
	_, channelID := slackid.ParsePortalID(s.PortalKey.ID)
	return channelID == "" || s.Client == nil || s.Client.isDMChannel(channelID)
}

// ShouldCreatePortal keeps a resync queued for a channel from creating its
// room if the channel was deselected in the meantime.
func (s *SlackChatResync) ShouldCreatePortal() bool {
	return s.SlackEventMeta.ShouldCreatePortal() && s.stillBridges()
}

func (s *SlackClient) switchboardMeta() *slackid.UserLoginMetadata {
	return s.UserLogin.Metadata.(*slackid.UserLoginMetadata)
}

// channelSelected reports whether a channel was chosen to bridge while
// dm_only keeps the rest out.
func (s *SlackClient) channelSelected(channelID string) bool {
	switchboardChannelsLock.RLock()
	defer switchboardChannelsLock.RUnlock()
	return s.switchboardMeta().SwitchboardChannels[channelID]
}

// replaceChannelSelection swaps in a changed copy of the selection and
// saves it. If the save fails the change is undone, so the bridge never
// acts on a selection it lost.
func (s *SlackClient) replaceChannelSelection(ctx context.Context, change func(selection map[string]bool, meta *slackid.UserLoginMetadata)) error {
	switchboardChannelsLock.Lock()
	defer switchboardChannelsLock.Unlock()
	meta := s.switchboardMeta()
	previous, previousSeeded := meta.SwitchboardChannels, meta.SwitchboardChannelsSeeded
	next := maps.Clone(previous)
	if next == nil {
		next = map[string]bool{}
	}
	change(next, meta)
	meta.SwitchboardChannels = next
	if err := saveSwitchboardLogin(ctx, s.UserLogin); err != nil {
		meta.SwitchboardChannels, meta.SwitchboardChannelsSeeded = previous, previousSeeded
		return err
	}
	return nil
}

func (s *SlackClient) setChannelSelected(ctx context.Context, channelID string, selected bool) error {
	return s.replaceChannelSelection(ctx, func(selection map[string]bool, _ *slackid.UserLoginMetadata) {
		if selected {
			selection[channelID] = true
		} else {
			delete(selection, channelID)
		}
	})
}

// seedChannelSelection runs once per login, the first time it connects with
// dm_only on: the channels it already bridges become its selection. They
// keep bridging, and nothing that wasn't bridged starts.
func (s *SlackClient) seedChannelSelection(ctx context.Context) {
	switchboardChannelsLock.RLock()
	seeded := s.switchboardMeta().SwitchboardChannelsSeeded
	switchboardChannelsLock.RUnlock()
	if seeded {
		return
	}
	log := zerolog.Ctx(ctx)
	channelIDs, err := bridgedSwitchboardChannelIDs(ctx, s)
	if err != nil {
		// Left unseeded, so the next connection tries again.
		log.Err(err).Msg("Failed to list bridged channels to seed the channel selection")
		return
	}
	err = s.replaceChannelSelection(ctx, func(selection map[string]bool, meta *slackid.UserLoginMetadata) {
		for _, channelID := range channelIDs {
			selection[channelID] = true
		}
		meta.SwitchboardChannelsSeeded = true
	})
	if err != nil {
		log.Err(err).Msg("Failed to save the seeded channel selection")
		return
	}
	log.Info().Int("channel_count", len(channelIDs)).Msg("Seeded the channel selection from the channels already bridged")
}

// selectedChannelsForSync collects the selected channels, for syncChannels
// to resync next to the DMs. Slack's boot response already describes the
// channels the account is in, so only the ones it left out are fetched: a
// lookup each would run into rate limits on a long selection. A channel the
// account has left, or that is gone, is skipped; it stays selected in case
// the account comes back.
func (s *SlackClient) selectedChannelsForSync(ctx context.Context) []*slack.Channel {
	switchboardChannelsLock.RLock()
	channelIDs := slices.Sorted(maps.Keys(s.switchboardMeta().SwitchboardChannels))
	switchboardChannelsLock.RUnlock()
	booted := map[string]*slack.Channel{}
	if s.BootResp != nil {
		for _, ch := range s.BootResp.Channels {
			// As upstream's sync has it: the boot response lists only
			// channels the account is in, without saying so.
			ch.IsMember = true
			booted[ch.ID] = &ch.Channel
		}
	}
	channels := make([]*slack.Channel, 0, len(channelIDs))
	for _, channelID := range channelIDs {
		if info := booted[channelID]; selectableChannel(info) {
			channels = append(channels, info)
			continue
		}
		info, err := fetchSwitchboardChannel(ctx, s, channelID)
		if err != nil {
			zerolog.Ctx(ctx).Err(err).Str("channel_id", channelID).Msg("Failed to fetch selected channel for sync")
		} else if selectableChannel(info) {
			channels = append(channels, info)
		}
	}
	return channels
}

// selectableChannel reports whether info is a channel (not a DM or group
// DM) the account is a member of.
func selectableChannel(info *slack.Channel) bool {
	return info != nil && !info.IsIM && !info.IsMpIM && info.IsMember && !info.IsArchived
}

type switchboardChannel struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Private  bool   `json:"private,omitempty"`
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

func (s *SlackClient) teamName() string {
	if s.BootResp != nil && s.BootResp.Team.Name != "" {
		return s.BootResp.Team.Name
	}
	return s.TeamID
}

// switchboardChannelGroups lists the channels the account is in, under its
// workspace, by name.
func (s *SlackClient) switchboardChannelGroups(ctx context.Context) ([]switchboardChannelGroup, error) {
	channels, err := listSwitchboardChannels(ctx, s)
	if err != nil {
		return nil, err
	}
	group := switchboardChannelGroup{ID: s.TeamID, Name: s.teamName()}
	for _, ch := range channels {
		if ch.IsIM || ch.IsMpIM || ch.IsArchived {
			continue
		}
		group.Channels = append(group.Channels, switchboardChannel{
			ID:      ch.ID,
			Name:    ch.Name,
			Private: ch.IsPrivate,
			// Without dm_only every one of them bridges.
			Selected: !s.Main.Config.DMOnly || s.channelSelected(ch.ID),
		})
	}
	if len(group.Channels) == 0 {
		return []switchboardChannelGroup{}, nil
	}
	slices.SortFunc(group.Channels, func(a, b switchboardChannel) int {
		return cmp.Or(cmp.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)), cmp.Compare(a.ID, b.ID))
	})
	return []switchboardChannelGroup{group}, nil
}

// switchboardLoginGetter is the part of the Matrix connector's provisioning
// API these endpoints need.
type switchboardLoginGetter interface {
	GetRouter() *http.ServeMux
	GetLoginForRequest(w http.ResponseWriter, r *http.Request) *bridgev2.UserLogin
}

// The build fails, rather than the endpoints going missing at run time, if
// a newer mautrix changes what the provisioning API offers.
var _ switchboardLoginGetter = (*matrix.ProvisioningAPI)(nil)

type switchboardAPI struct {
	prov switchboardLoginGetter
}

func (s *SlackConnector) setUpSwitchboardChannels() {
	log := s.br.Log.With().Str("component", "switchboard channels").Logger()
	c, ok := s.br.Matrix.(bridgev2.MatrixConnectorWithProvisioning)
	if !ok {
		log.Warn().Msg("Matrix connector doesn't support provisioning; channel selection is unavailable")
		return
	}
	prov, ok := c.GetProvisioning().(switchboardLoginGetter)
	if !ok || prov.GetRouter() == nil {
		log.Warn().Msg("Provisioning API has no router; channel selection is unavailable")
		return
	}
	(&switchboardAPI{prov: prov}).register(prov.GetRouter())
}

func (a *switchboardAPI) register(r *http.ServeMux) {
	r.HandleFunc("GET /switchboard/v1/channels", a.handler(a.listChannels, true))
	r.HandleFunc("PUT /switchboard/v1/channels/{groupID}/{channelID}", a.handler(a.selectChannel, true))
	// Deselecting only changes what the bridge keeps, so it works while the
	// login is disconnected too.
	r.HandleFunc("DELETE /switchboard/v1/channels/{groupID}/{channelID}", a.handler(a.deselectChannel, false))
}

func (a *switchboardAPI) handler(next func(http.ResponseWriter, *http.Request, *SlackClient), needsConnection bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		login := a.prov.GetLoginForRequest(w, r)
		if login == nil {
			return
		}
		client, ok := login.Client.(*SlackClient)
		if !ok || (needsConnection && !client.IsLoggedIn()) {
			mautrix.RespError{
				ErrCode:    "FI.MAU.SLACK.NOT_CONNECTED",
				Err:        "Not logged in to Slack",
				StatusCode: http.StatusBadRequest,
			}.Write(w)
			return
		}
		next(w, r, client)
	}
}

func (a *switchboardAPI) listChannels(w http.ResponseWriter, r *http.Request, client *SlackClient) {
	groups, err := client.switchboardChannelGroups(r.Context())
	if err != nil {
		zerolog.Ctx(r.Context()).Err(err).Msg("Failed to list channels for channel selection")
		mautrix.MUnknown.WithMessage("Couldn't fetch channels from Slack: %v", err).WithStatus(http.StatusBadGateway).Write(w)
		return
	}
	exhttp.WriteJSONResponse(w, http.StatusOK, respSwitchboardChannels{Groups: groups})
}

func (a *switchboardAPI) selectChannel(w http.ResponseWriter, r *http.Request, client *SlackClient) {
	ctx := r.Context()
	channelID := r.PathValue("channelID")
	if r.PathValue("groupID") != client.TeamID {
		mautrix.MNotFound.WithMessage("This account isn't in that workspace").Write(w)
		return
	}
	// Asked of Slack now, not read from the cache: what the list offered
	// came from Slack a moment ago, and the two must agree.
	info, err := client.fetchChatInfoFresh(ctx, channelID)
	if err != nil && !slackSaysNoSuchChannel(err) {
		zerolog.Ctx(ctx).Err(err).Str("channel_id", channelID).Msg("Failed to check channel before selecting it")
		mautrix.MUnknown.WithMessage("Couldn't check that channel with Slack: %v", err).WithStatus(http.StatusBadGateway).Write(w)
		return
	} else if err != nil || !selectableChannel(info) {
		zerolog.Ctx(ctx).Debug().Err(err).Str("channel_id", channelID).Msg("Refusing to select channel")
		mautrix.MNotFound.WithMessage("This account isn't in that channel").Write(w)
		return
	}
	resp := respSwitchboardChannel{GroupID: client.TeamID, ID: channelID, Selected: true}
	if !client.Main.Config.DMOnly {
		// Every channel already bridges.
		exhttp.WriteJSONResponse(w, http.StatusOK, resp)
		return
	}
	if err = client.setChannelSelected(ctx, channelID, true); err != nil {
		zerolog.Ctx(ctx).Err(err).Str("channel_id", channelID).Msg("Failed to save channel selection")
		mautrix.MUnknown.WithMessage("Couldn't save the selection: %v", err).Write(w)
		return
	}
	// Creates the channel's room, or catches an existing one up.
	syncSwitchboardChannel(client, info)
	exhttp.WriteJSONResponse(w, http.StatusOK, resp)
}

func (a *switchboardAPI) deselectChannel(w http.ResponseWriter, r *http.Request, client *SlackClient) {
	ctx := r.Context()
	channelID := r.PathValue("channelID")
	if !client.Main.Config.DMOnly {
		errSwitchboardEveryChannelBridged.Write(w)
		return
	}
	if err := client.setChannelSelected(ctx, channelID, false); err != nil {
		zerolog.Ctx(ctx).Err(err).Str("channel_id", channelID).Msg("Failed to save channel selection")
		mautrix.MUnknown.WithMessage("Couldn't save the selection: %v", err).Write(w)
		return
	}
	exhttp.WriteJSONResponse(w, http.StatusOK, respSwitchboardChannel{GroupID: client.TeamID, ID: channelID, Selected: false})
}
