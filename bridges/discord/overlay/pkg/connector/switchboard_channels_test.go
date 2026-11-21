// Switchboard addition to mautrix-discord. AGPL-3.0-or-later, like the bridge.

package connector

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/bwmarrin/discordgo"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"

	"go.mau.fi/mautrix-discord/pkg/discordid"
	"go.mau.fi/mautrix-discord/pkg/router"
)

const switchboardTestUser = "100"

// fakeProvisioning hands each request the login named by ?login_id=, as the
// real provisioning API does.
type fakeProvisioning struct {
	mux    *http.ServeMux
	logins map[string]*bridgev2.UserLogin
}

func (f *fakeProvisioning) GetRouter() *http.ServeMux              { return f.mux }
func (f *fakeProvisioning) GetUser(r *http.Request) *bridgev2.User { return nil }
func (f *fakeProvisioning) GetExplicitLoginForRequest(w http.ResponseWriter, r *http.Request) (*bridgev2.UserLogin, bool) {
	login := f.logins[r.URL.Query().Get("login_id")]
	if login == nil {
		http.Error(w, `{"errcode":"M_NOT_FOUND","error":"Login not found"}`, http.StatusNotFound)
		return nil, true
	}
	return login, false
}
func (f *fakeProvisioning) GetLoginForRequest(w http.ResponseWriter, r *http.Request) *bridgev2.UserLogin {
	login, _ := f.GetExplicitLoginForRequest(w, r)
	return login
}

type switchboardFixture struct {
	t       *testing.T
	api     *fakeProvisioning
	saveErr error
	saves   int
	synced  []string

	// The fixture answers the logins' Discord REST calls itself (see
	// RoundTrip): own guild membership and channel messages.
	memberLookupErr error
	memberLookups   map[string]int
	historyCalls    map[string]int
	history         map[string][]*discordgo.Message
	// Runs while a request for channel messages is being answered.
	duringHistory func()
}

// RoundTrip stands in for Discord's REST API.
func (f *switchboardFixture) RoundTrip(req *http.Request) (*http.Response, error) {
	parts := strings.Split(strings.Trim(req.URL.Path, "/"), "/")
	var body any
	switch n := len(parts); {
	case n >= 4 && parts[n-4] == "guilds" && parts[n-2] == "members":
		f.memberLookups[parts[n-3]]++
		if f.memberLookupErr != nil {
			return nil, f.memberLookupErr
		}
		body = &discordgo.Member{User: &discordgo.User{ID: parts[n-1]}}
	case n >= 3 && parts[n-3] == "channels" && parts[n-1] == "messages":
		channelID := parts[n-2]
		f.historyCalls[channelID]++
		if f.duringHistory != nil {
			f.duringHistory()
		}
		body = append([]*discordgo.Message{}, f.history[channelID]...)
	default:
		f.t.Errorf("unexpected Discord API call %s %s", req.Method, req.URL)
		return nil, errors.New("unexpected request")
	}
	data, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(string(data))),
		Request:    req,
	}, nil
}

// Two guilds that both have a #general. Harbour also has a category, a
// channel hidden from the account, a voice channel and an announcements
// channel.
func switchboardGuilds() []*discordgo.Guild {
	everyone := func(guildID string) []*discordgo.Role {
		return []*discordgo.Role{{ID: guildID, Permissions: discordgo.PermissionViewChannel}}
	}
	me := func(guildID string) []*discordgo.Member {
		return []*discordgo.Member{{GuildID: guildID, User: &discordgo.User{ID: switchboardTestUser}}}
	}
	return []*discordgo.Guild{
		{
			ID: "g-harbour", Name: "Harbour", OwnerID: "999", Roles: everyone("g-harbour"), Members: me("g-harbour"),
			Channels: []*discordgo.Channel{
				{ID: "c-cat", GuildID: "g-harbour", Name: "Projects", Type: discordgo.ChannelTypeGuildCategory, Position: 1},
				{ID: "c-build", GuildID: "g-harbour", Name: "build", Type: discordgo.ChannelTypeGuildText, ParentID: "c-cat", Position: 0},
				{ID: "c-general", GuildID: "g-harbour", Name: "general", Type: discordgo.ChannelTypeGuildText, Position: 0},
				{ID: "c-news", GuildID: "g-harbour", Name: "news", Type: discordgo.ChannelTypeGuildNews, Position: 1},
				{ID: "c-voice", GuildID: "g-harbour", Name: "Lounge", Type: discordgo.ChannelTypeGuildVoice, Position: 2},
				{
					ID: "c-mods", GuildID: "g-harbour", Name: "mods", Type: discordgo.ChannelTypeGuildText, Position: 3,
					PermissionOverwrites: []*discordgo.PermissionOverwrite{
						{ID: "g-harbour", Type: discordgo.PermissionOverwriteTypeRole, Deny: discordgo.PermissionViewChannel},
					},
				},
			},
		},
		{
			ID: "g-atlas", Name: "Atlas", OwnerID: "999", Roles: everyone("g-atlas"), Members: me("g-atlas"),
			Channels: []*discordgo.Channel{
				{ID: "c-atlas-general", GuildID: "g-atlas", Name: "general", Type: discordgo.ChannelTypeGuildText},
			},
		},
	}
}

func (f *switchboardFixture) addLogin(id string, meta *discordid.UserLoginMetadata, cfg Config) *DiscordClient {
	f.t.Helper()
	state := discordgo.NewState()
	state.User = &discordgo.User{ID: switchboardTestUser}
	for _, guild := range switchboardGuilds() {
		if err := state.GuildAdd(guild); err != nil {
			f.t.Fatal(err)
		}
	}
	dm := &discordgo.Channel{ID: "c-dm", Type: discordgo.ChannelTypeDM}
	if err := state.ChannelAdd(dm); err != nil {
		f.t.Fatal(err)
	}
	meta.Token = "token"
	login := &bridgev2.UserLogin{UserLogin: &database.UserLogin{ID: networkid.UserLoginID(id), Metadata: meta}}
	session, err := discordgo.New("token")
	if err != nil {
		f.t.Fatal(err)
	}
	session.State = state
	session.Client = &http.Client{Transport: f}
	client := &DiscordClient{
		connector:       &DiscordConnector{Config: cfg},
		UserLogin:       login,
		Session:         session,
		historyFetchSem: make(chan struct{}, maxConcurrentHistoryFetches),
	}
	login.Client = client
	f.api.logins[id] = login
	return client
}

func newSwitchboardFixture(t *testing.T) *switchboardFixture {
	f := &switchboardFixture{
		t:             t,
		api:           &fakeProvisioning{mux: http.NewServeMux(), logins: map[string]*bridgev2.UserLogin{}},
		memberLookups: map[string]int{},
		historyCalls:  map[string]int{},
		history:       map[string][]*discordgo.Message{},
	}
	oldSave, oldSync := saveSwitchboardLogin, syncSwitchboardGuild
	saveSwitchboardLogin = func(context.Context, *bridgev2.UserLogin) error {
		f.saves++
		return f.saveErr
	}
	syncSwitchboardGuild = func(_ *DiscordClient, guildID string) { f.synced = append(f.synced, guildID) }
	t.Cleanup(func() { saveSwitchboardLogin, syncSwitchboardGuild = oldSave, oldSync })
	(&ProvisioningAPI{prov: f.api}).registerSwitchboardChannels(f.api.mux)
	return f
}

func (f *switchboardFixture) do(method, path string) (int, map[string]any) {
	f.t.Helper()
	rec := httptest.NewRecorder()
	f.api.mux.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		f.t.Fatalf("%s %s: bad JSON %q: %v", method, path, rec.Body.String(), err)
	}
	return rec.Code, body
}

// list returns "Group/#channel" (with "[section]" when in a category) for
// every offered channel, and the subset that is selected.
func (f *switchboardFixture) list(loginID string) (offered, selected []string) {
	f.t.Helper()
	rec := httptest.NewRecorder()
	f.api.mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/switchboard/v1/channels?login_id="+loginID, nil))
	if rec.Code != http.StatusOK {
		f.t.Fatalf("list: HTTP %d: %s", rec.Code, rec.Body.String())
	}
	var resp respSwitchboardChannels
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		f.t.Fatal(err)
	}
	for _, group := range resp.Groups {
		for _, ch := range group.Channels {
			name := group.Name + "/#" + ch.Name
			if ch.Section != "" {
				name += " [" + ch.Section + "]"
			}
			offered = append(offered, name)
			if ch.Selected {
				selected = append(selected, name)
			}
		}
	}
	return offered, selected
}

func expectStrings(t *testing.T, what string, got, want []string) {
	t.Helper()
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%s: got %q, want %q", what, got, want)
	}
}

func TestSwitchboardListsVisibleChannelsByGuild(t *testing.T) {
	f := newSwitchboardFixture(t)
	f.addLogin("1", &discordid.UserLoginMetadata{}, Config{})

	offered, selected := f.list("1")
	// Guilds by name; loose channels before categories; the hidden channel,
	// the voice channel and the category itself are not offered.
	expectStrings(t, "offered", offered, []string{
		"Atlas/#general",
		"Harbour/#general", "Harbour/#news", "Harbour/#build [Projects]",
	})
	// A login that never chose anything bridges no guild channel.
	expectStrings(t, "selected", selected, nil)
}

func TestSwitchboardSelectAndDeselect(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("1", &discordid.UserLoginMetadata{}, Config{})
	other := f.addLogin("2", &discordid.UserLoginMetadata{
		SwitchboardChannels: map[string]map[string]bool{"g-atlas": {"c-atlas-general": true}},
	}, Config{})
	ctx := context.Background()
	general := client.channelWithID(ctx, "c-general")
	route := &router.Route{PortalChannelID: "c-general"}

	if client.shouldBridgeChannel(ctx, general) {
		t.Fatal("an unselected channel must not bridge")
	}
	if got := client.guildIDsToSync(); len(got) != 0 {
		t.Fatalf("nothing is selected, but %q would sync", got)
	}

	status, body := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-general?login_id=1")
	if status != http.StatusOK || body["selected"] != true {
		t.Fatalf("select: HTTP %d %v", status, body)
	}
	if !client.shouldBridgeChannel(ctx, general) || !client.routeSelected(ctx, route) {
		t.Error("a selected channel must bridge")
	}
	if client.shouldBridgeChannel(ctx, client.channelWithID(ctx, "c-news")) {
		t.Error("selecting one channel must not bridge its neighbours")
	}
	expectStrings(t, "synced guilds", f.synced, []string{"g-harbour"})
	expectStrings(t, "guilds to sync", client.guildIDsToSync(), []string{"g-harbour"})
	if !client.guildHasBridgedChannels("g-harbour") || client.guildHasBridgedChannels("g-atlas") {
		t.Error("only the guild with a selected channel has bridged channels")
	}
	_, selected := f.list("1")
	expectStrings(t, "selected after select", selected, []string{"Harbour/#general"})

	status, body = f.do(http.MethodDelete, "/switchboard/v1/channels/g-harbour/c-general?login_id=1")
	if status != http.StatusOK || body["selected"] != false {
		t.Fatalf("deselect: HTTP %d %v", status, body)
	}
	// New messages stop: neither a fresh portal nor the existing one passes.
	if client.shouldBridgeChannel(ctx, general) || client.routeSelected(ctx, route) {
		t.Error("a deselected channel must stop bridging")
	}
	_, selected = f.list("1")
	expectStrings(t, "selected after deselect", selected, nil)
	if len(client.userLoginMetadata().SwitchboardChannels) != 0 {
		t.Errorf("deselecting the last channel should leave no entry: %v", client.userLoginMetadata().SwitchboardChannels)
	}

	// The other account's selection was never touched.
	_, selected = f.list("2")
	expectStrings(t, "other login", selected, []string{"Atlas/#general"})
	if !other.shouldBridgeChannel(ctx, other.channelWithID(ctx, "c-atlas-general")) {
		t.Error("the other login's channel must keep bridging")
	}
	if f.saves != 2 {
		t.Errorf("expected one save per change, got %d", f.saves)
	}
}

func TestSwitchboardRejectsChannelsTheAccountCannotSee(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("1", &discordid.UserLoginMetadata{}, Config{})

	for _, path := range []string{
		"/switchboard/v1/channels/g-harbour/c-mods",        // hidden by permissions
		"/switchboard/v1/channels/g-harbour/c-voice",       // not a text channel
		"/switchboard/v1/channels/g-harbour/c-cat",         // a category
		"/switchboard/v1/channels/g-harbour/c-nonexistent", // unknown
		"/switchboard/v1/channels/g-atlas/c-general",       // another guild's channel
		"/switchboard/v1/channels/g-harbour/c-dm",          // a DM
	} {
		status, body := f.do(http.MethodPut, path+"?login_id=1")
		if status != http.StatusNotFound || body["errcode"] != "M_NOT_FOUND" {
			t.Errorf("%s: HTTP %d %v", path, status, body)
		}
	}
	if f.saves != 0 || len(f.synced) != 0 || len(client.userLoginMetadata().SwitchboardChannels) != 0 {
		t.Error("a rejected selection must change nothing")
	}
	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-general?login_id=nobody"); status != http.StatusNotFound {
		t.Errorf("unknown login: HTTP %d", status)
	}
}

func TestSwitchboardOffersOnlyChannelsConfirmedVisible(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("1", &discordid.UserLoginMetadata{}, Config{})
	ctx := context.Background()
	// The login's own membership of Harbour, and with it its roles there,
	// is missing from the cache, and Discord can't be asked for it.
	err := client.Session.State.MemberRemove(&discordgo.Member{GuildID: "g-harbour", User: &discordgo.User{ID: switchboardTestUser}})
	if err != nil {
		t.Fatal(err)
	}
	f.memberLookupErr = errors.New("connection reset by peer")

	// Upstream's check can't tell and says yes, even for the hidden channel.
	if !client.canSeeGuildChannel(ctx, client.channelWithID(ctx, "c-mods")) {
		t.Fatal("expected upstream's check to pass a channel it can't work out")
	}
	f.memberLookups = map[string]int{}

	// None of Harbour's channels are offered; Atlas is unaffected.
	offered, _ := f.list("1")
	expectStrings(t, "offered while visibility is unknown", offered, []string{"Atlas/#general"})
	if f.memberLookups["g-harbour"] != 1 {
		t.Errorf("expected one membership lookup for the guild, got %d", f.memberLookups["g-harbour"])
	}
	// And none can be selected, hidden or not: not knowing is a failure.
	for _, channelID := range []string{"c-mods", "c-general"} {
		status, body := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/"+channelID+"?login_id=1")
		if status != http.StatusBadGateway || body["errcode"] != "M_UNKNOWN" {
			t.Errorf("%s while visibility is unknown: HTTP %d %v", channelID, status, body)
		}
	}
	if f.saves != 0 || len(f.synced) != 0 || len(client.userLoginMetadata().SwitchboardChannels) != 0 {
		t.Error("an unconfirmed selection must change nothing")
	}

	// Once Discord answers, the visible channels are offered and the hidden
	// one is refused as such.
	f.memberLookupErr = nil
	offered, _ = f.list("1")
	expectStrings(t, "offered once membership is known", offered, []string{
		"Atlas/#general",
		"Harbour/#general", "Harbour/#news", "Harbour/#build [Projects]",
	})
	if status, body := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-mods?login_id=1"); status != http.StatusNotFound {
		t.Errorf("hidden channel: HTTP %d %v", status, body)
	}
	if status, body := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-general?login_id=1"); status != http.StatusOK {
		t.Errorf("visible channel: HTTP %d %v", status, body)
	}
}

func TestSwitchboardQueuedWorkStopsAfterDeselect(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("1", &discordid.UserLoginMetadata{}, Config{})
	ctx := context.Background()
	general := client.channelWithID(ctx, "c-general")
	general.LastMessageID = "1300000000000000001"
	portal := func(channelID, guildID string) *bridgev2.Portal {
		return &bridgev2.Portal{Portal: &database.Portal{
			PortalKey: networkid.PortalKey{ID: discordid.MakeChannelPortalIDWithID(channelID)},
			Metadata:  &discordid.PortalMetadata{GuildID: guildID},
		}}
	}
	fetch := func(forward bool) *bridgev2.FetchMessagesResponse {
		t.Helper()
		resp, err := client.FetchMessages(ctx, bridgev2.FetchMessagesParams{
			Portal: portal("c-general", "g-harbour"), Forward: forward, Count: 50,
		})
		if err != nil || resp == nil {
			t.Fatalf("FetchMessages: %v, %v", resp, err)
		}
		return resp
	}

	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-general?login_id=1"); status != http.StatusOK {
		t.Fatalf("select: HTTP %d", status)
	}
	expectStrings(t, "synced guilds", f.synced, []string{"g-harbour"})
	// What the guild sync queues for the channel: the resync that creates
	// its room and fetches its messages. Here it is held, not run.
	resync := &DiscordChatResync{Client: client, channel: general, createPortal: true}
	if needs, _ := resync.CheckNeedsBackfill(ctx, nil); !resync.ShouldCreatePortal() || !needs {
		t.Fatal("while selected, the queued resync creates the room and fetches messages")
	}
	fetch(true)
	if f.historyCalls["c-general"] != 1 {
		t.Fatalf("while selected, messages are fetched: %d requests", f.historyCalls["c-general"])
	}

	// The channel is turned off before the queued work runs.
	if status, _ := f.do(http.MethodDelete, "/switchboard/v1/channels/g-harbour/c-general?login_id=1"); status != http.StatusOK {
		t.Fatalf("deselect: HTTP %d", status)
	}
	// A message arrives after that.
	f.history["c-general"] = []*discordgo.Message{{
		ID: "1300000000000000002", ChannelID: "c-general", GuildID: "g-harbour",
		Content: "after", Author: &discordgo.User{ID: "200", Username: "bela"},
	}}

	// Resumed, the resync neither creates the room nor fetches anything.
	if resync.ShouldCreatePortal() {
		t.Error("a resync queued before the deselect must not create the room")
	}
	if needs, err := resync.CheckNeedsBackfill(ctx, nil); needs || err != nil {
		t.Errorf("a resync queued before the deselect must not ask for messages: %v, %v", needs, err)
	}
	if resp := fetch(true); len(resp.Messages) != 0 {
		t.Errorf("catch-up after the deselect brought in %d messages", len(resp.Messages))
	}
	// The history queue is put off, not told the channel is finished.
	if resp := fetch(false); len(resp.Messages) != 0 || !resp.Pending {
		t.Errorf("history after the deselect: %d messages, pending=%v", len(resp.Messages), resp.Pending)
	}
	if f.historyCalls["c-general"] != 1 {
		t.Errorf("a deselected channel must not be fetched: %d requests", f.historyCalls["c-general"])
	}

	// Turned off while Discord is answering a fetch that had already begun:
	// what comes back is dropped too.
	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-general?login_id=1"); status != http.StatusOK {
		t.Fatalf("reselect: HTTP %d", status)
	}
	f.duringHistory = func() {
		if status, _ := f.do(http.MethodDelete, "/switchboard/v1/channels/g-harbour/c-general?login_id=1"); status != http.StatusOK {
			t.Errorf("deselect during fetch: HTTP %d", status)
		}
	}
	if resp := fetch(true); len(resp.Messages) != 0 {
		t.Errorf("a fetch overtaken by the deselect brought in %d messages", len(resp.Messages))
	}
	if f.historyCalls["c-general"] != 2 {
		t.Errorf("the overtaken fetch should have reached Discord once: %d requests", f.historyCalls["c-general"])
	}
	f.duringHistory = nil

	// A portal that doesn't know its guild yet is no way round the choice.
	if client.backfillAllowed(portal("c-general", "")) {
		t.Error("a deselected channel must not be fetched through a portal without its guild")
	}

	// DMs are fetched and resynced whatever is selected.
	if !client.backfillAllowed(portal("c-dm", "")) {
		t.Error("DMs must keep fetching messages")
	}
	dm := &DiscordChatResync{Client: client, channel: client.channelWithID(ctx, "c-dm"), createPortal: true}
	if !dm.ShouldCreatePortal() {
		t.Error("a DM's resync must still create its room")
	}
}

func TestSwitchboardFailedSaveLeavesSelectionUnchanged(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("1", &discordid.UserLoginMetadata{
		SwitchboardChannels: map[string]map[string]bool{"g-harbour": {"c-news": true}},
	}, Config{})
	ctx := context.Background()
	f.saveErr = errors.New("database is locked")

	status, body := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-general?login_id=1")
	if status != http.StatusInternalServerError || body["error"] == nil {
		t.Fatalf("select with failing save: HTTP %d %v", status, body)
	}
	status, _ = f.do(http.MethodDelete, "/switchboard/v1/channels/g-harbour/c-news?login_id=1")
	if status != http.StatusInternalServerError {
		t.Fatalf("deselect with failing save: HTTP %d", status)
	}
	if client.shouldBridgeChannel(ctx, client.channelWithID(ctx, "c-general")) {
		t.Error("an unsaved selection must not bridge")
	}
	if !client.shouldBridgeChannel(ctx, client.channelWithID(ctx, "c-news")) {
		t.Error("an unsaved deselection must keep bridging")
	}
	_, selected := f.list("1")
	expectStrings(t, "selected", selected, []string{"Harbour/#news"})
	if len(f.synced) != 0 {
		t.Error("nothing should sync when the save failed")
	}
}

func TestSwitchboardWhollyBridgedGuildKeepsBridging(t *testing.T) {
	f := newSwitchboardFixture(t)
	// Bridged whole before the upgrade: one through upstream's guild API,
	// one through the config file.
	client := f.addLogin("1", &discordid.UserLoginMetadata{
		BridgedGuildIDs: map[string]bool{"g-harbour": true},
	}, Config{Guilds: struct {
		BridgingGuildIDs []string `yaml:"bridging_guild_ids"`
	}{BridgingGuildIDs: []string{"g-atlas"}}})
	ctx := context.Background()

	_, selected := f.list("1")
	expectStrings(t, "selected", selected, []string{
		"Atlas/#general",
		"Harbour/#general", "Harbour/#news", "Harbour/#build [Projects]",
	})

	// One channel of it can still be taken out, and put back.
	if status, _ := f.do(http.MethodDelete, "/switchboard/v1/channels/g-harbour/c-news?login_id=1"); status != http.StatusOK {
		t.Fatalf("deselect: HTTP %d", status)
	}
	if client.shouldBridgeChannel(ctx, client.channelWithID(ctx, "c-news")) {
		t.Error("the deselected channel must stop bridging")
	}
	if !client.shouldBridgeChannel(ctx, client.channelWithID(ctx, "c-general")) {
		t.Error("the rest of the guild must keep bridging")
	}
	expectStrings(t, "guilds to sync", client.guildIDsToSync(), []string{"g-atlas", "g-harbour"})
	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/g-harbour/c-news?login_id=1"); status != http.StatusOK {
		t.Fatalf("reselect: HTTP %d", status)
	}
	if !client.shouldBridgeChannel(ctx, client.channelWithID(ctx, "c-news")) {
		t.Error("the reselected channel must bridge again")
	}
}

func TestSwitchboardDMsAndUnknownChannelsAreNotFiltered(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("1", &discordid.UserLoginMetadata{}, Config{})
	ctx := context.Background()

	for _, channelID := range []string{"c-dm", "c-cat", "c-not-in-cache"} {
		if !client.routeSelected(ctx, &router.Route{PortalChannelID: channelID}) {
			t.Errorf("%s: only guild text channels can be deselected", channelID)
		}
	}
	if !client.routeSelected(ctx, nil) {
		t.Error("a missing route is left to the caller")
	}
}

func TestSwitchboardSelectionSurvivesRelogin(t *testing.T) {
	meta := &discordid.UserLoginMetadata{
		Token:               "old",
		BridgedGuildIDs:     map[string]bool{"g-atlas": true},
		SwitchboardChannels: map[string]map[string]bool{"g-harbour": {"c-general": true}},
	}
	meta.CopyFrom(&discordid.UserLoginMetadata{Token: "new"})
	if meta.Token != "new" || !meta.SwitchboardChannels["g-harbour"]["c-general"] || !meta.BridgedGuildIDs["g-atlas"] {
		t.Errorf("relinking must keep the channel selection: %+v", meta)
	}

	// And it round-trips through the database's JSON column.
	data, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	var loaded discordid.UserLoginMetadata
	if err = json.Unmarshal(data, &loaded); err != nil {
		t.Fatal(err)
	}
	if !loaded.SwitchboardChannels["g-harbour"]["c-general"] {
		t.Errorf("selection lost in storage: %s", data)
	}
}
