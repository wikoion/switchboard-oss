// Switchboard addition to mautrix-slack. AGPL-3.0-or-later, like the bridge.

package connector

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"go.mau.fi/util/exsync"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"

	"go.mau.fi/mautrix-slack/pkg/slackid"
)

// fakeSwitchboardProvisioning hands each request the login named by
// ?login_id=, as the real provisioning API does.
type fakeSwitchboardProvisioning struct {
	mux    *http.ServeMux
	logins map[string]*bridgev2.UserLogin
}

func (f *fakeSwitchboardProvisioning) GetRouter() *http.ServeMux { return f.mux }
func (f *fakeSwitchboardProvisioning) GetLoginForRequest(w http.ResponseWriter, r *http.Request) *bridgev2.UserLogin {
	login := f.logins[r.URL.Query().Get("login_id")]
	if login == nil {
		http.Error(w, `{"errcode":"M_NOT_FOUND","error":"Login not found"}`, http.StatusNotFound)
	}
	return login
}

type switchboardFixture struct {
	t        *testing.T
	api      *fakeSwitchboardProvisioning
	saveErr  error
	listErr  error
	saves    int
	synced   []string
	channels map[string]*slack.Channel
	// A stand-in for Slack's web API, answering conversations.info from
	// channels and conversations.history from history.
	slack *httptest.Server
	// Set to make the stand-in fail outright instead of answering.
	slackDown bool
	// How often each channel was asked for, by API method.
	infoCalls, historyCalls map[string]int
	history                 map[string][]slack.Message
	// Runs while a conversations.history request is being answered.
	duringHistory func()
	// The resyncs selecting a channel queued, held until a test runs them.
	queued []*SlackChatResync
	// Channel IDs each login had rooms for before selection existed.
	bridged map[networkid.UserLoginID][]string
}

func slackChannel(id, name string, edit ...func(*slack.Channel)) *slack.Channel {
	ch := &slack.Channel{IsChannel: true, IsMember: true}
	ch.ID = id
	ch.Name = name
	for _, fn := range edit {
		fn(ch)
	}
	return ch
}

func newSwitchboardFixture(t *testing.T) *switchboardFixture {
	f := &switchboardFixture{
		t:       t,
		api:     &fakeSwitchboardProvisioning{mux: http.NewServeMux(), logins: map[string]*bridgev2.UserLogin{}},
		bridged: map[networkid.UserLoginID][]string{},
		channels: map[string]*slack.Channel{
			"C1": slackChannel("C1", "general"),
			"C2": slackChannel("C2", "Design"),
			"C3": slackChannel("C3", "leadership", func(ch *slack.Channel) { ch.IsPrivate = true }),
			// Visible in the workspace, but the account hasn't joined it.
			"C4": slackChannel("C4", "random", func(ch *slack.Channel) { ch.IsMember = false }),
			"C5": slackChannel("C5", "old-project", func(ch *slack.Channel) { ch.IsArchived = true }),
			"G1": slackChannel("G1", "mpdm-ada--bela-1", func(ch *slack.Channel) { ch.IsMpIM = true }),
			"D1": slackChannel("D1", "", func(ch *slack.Channel) { ch.IsIM = true }),
		},
	}
	f.infoCalls, f.historyCalls, f.history = map[string]int{}, map[string]int{}, map[string][]slack.Message{}
	f.slack = httptest.NewServer(http.HandlerFunc(f.serveSlack))
	t.Cleanup(f.slack.Close)
	oldSave, oldFetch, oldList, oldBridged, oldSync := saveSwitchboardLogin, fetchSwitchboardChannel,
		listSwitchboardChannels, bridgedSwitchboardChannelIDs, syncSwitchboardChannel
	t.Cleanup(func() {
		saveSwitchboardLogin, fetchSwitchboardChannel, listSwitchboardChannels, bridgedSwitchboardChannelIDs,
			syncSwitchboardChannel = oldSave, oldFetch, oldList, oldBridged, oldSync
	})
	saveSwitchboardLogin = func(context.Context, *bridgev2.UserLogin) error {
		f.saves++
		return f.saveErr
	}
	fetchSwitchboardChannel = func(_ context.Context, _ *SlackClient, channelID string) (*slack.Channel, error) {
		if ch := f.channels[channelID]; ch != nil {
			return ch, nil
		}
		return nil, errors.New("channel_not_found")
	}
	// users.conversations: what the account is a member of.
	listSwitchboardChannels = func(context.Context, *SlackClient) ([]slack.Channel, error) {
		if f.listErr != nil {
			return nil, f.listErr
		}
		var out []slack.Channel
		for _, id := range []string{"C1", "C2", "C3", "C5", "G1"} {
			out = append(out, *f.channels[id])
		}
		return out, nil
	}
	bridgedSwitchboardChannelIDs = func(_ context.Context, s *SlackClient) ([]string, error) {
		return f.bridged[s.UserLogin.ID], nil
	}
	syncSwitchboardChannel = func(s *SlackClient, info *slack.Channel) {
		f.synced = append(f.synced, info.ID)
		f.queued = append(f.queued, s.newSwitchboardResync(info, false))
	}
	(&switchboardAPI{prov: f.api}).register(f.api.mux)
	return f
}

func (f *switchboardFixture) serveSlack(w http.ResponseWriter, r *http.Request) {
	channelID := r.FormValue("channel")
	if f.slackDown {
		http.Error(w, "upstream connect error", http.StatusServiceUnavailable)
		return
	}
	var resp any
	switch r.URL.Path {
	case "/conversations.info":
		f.infoCalls[channelID]++
		if ch := f.channels[channelID]; ch != nil {
			resp = map[string]any{"ok": true, "channel": ch}
		}
	case "/conversations.history":
		f.historyCalls[channelID]++
		if f.duringHistory != nil {
			f.duringHistory()
		}
		if f.channels[channelID] != nil {
			resp = map[string]any{"ok": true, "messages": f.history[channelID]}
		}
	default:
		f.t.Errorf("unexpected Slack API call %s", r.URL.Path)
	}
	if resp == nil {
		resp = map[string]any{"ok": false, "error": "channel_not_found"}
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		f.t.Error(err)
	}
}

func (f *switchboardFixture) portal(client *SlackClient, channelID string, roomType database.RoomType) *bridgev2.Portal {
	return &bridgev2.Portal{Portal: &database.Portal{
		PortalKey: networkid.PortalKey{ID: slackid.MakePortalID(client.TeamID, channelID)},
		RoomType:  roomType,
	}}
}

func (f *switchboardFixture) addLogin(id, teamID, teamName string, dmOnly bool, meta *slackid.UserLoginMetadata) *SlackClient {
	login := &bridgev2.UserLogin{UserLogin: &database.UserLogin{ID: networkid.UserLoginID(id), Metadata: meta}}
	boot := &slack.ClientUserBootResponse{}
	boot.Team.Name = teamName
	client := &SlackClient{
		Main:         &SlackConnector{Config: Config{DMOnly: dmOnly}},
		UserLogin:    login,
		Client:       slack.New("xoxc-test", slack.OptionAPIURL(f.slack.URL+"/")),
		TeamID:       teamID,
		UserID:       "U1",
		BootResp:     boot,
		dmChannelIDs: exsync.NewSet[string](),

		chatInfoCache:          map[string]chatInfoCacheEntry{},
		chatInfoFetchAttempted: map[string]bool{},
		lastReadCache:          map[string]string{},
	}
	login.Client = client
	f.api.logins[id] = login
	return client
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

// list returns "Workspace/#channel" for every offered channel ("/🔒" for
// private ones), and the subset that is selected.
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
			if ch.Private {
				name = group.Name + "/🔒" + ch.Name
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

func TestSwitchboardListsJoinedChannelsByWorkspace(t *testing.T) {
	f := newSwitchboardFixture(t)
	f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})

	offered, selected := f.list("T1-U1")
	// By name; the group DM and the archived channel are not offered, and
	// the channel the account hasn't joined never comes back from Slack.
	expectStrings(t, "offered", offered, []string{"Northwind/#Design", "Northwind/#general", "Northwind/🔒leadership"})
	expectStrings(t, "selected", selected, nil)

	f.listErr = errors.New("ratelimited")
	status, body := f.do(http.MethodGet, "/switchboard/v1/channels?login_id=T1-U1")
	if status != http.StatusBadGateway || body["error"] == nil {
		t.Errorf("list while Slack fails: HTTP %d %v", status, body)
	}
}

func TestSwitchboardSelectAndDeselect(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})
	other := f.addLogin("T2-U9", "T2", "Atlas", true, &slackid.UserLoginMetadata{
		SwitchboardChannels: map[string]bool{"C2": true},
	})
	ctx := context.Background()
	message := &slack.MessageEvent{}
	message.Channel = "C1"

	// Before it is selected, nothing from the channel gets through.
	if client.isDMChannel("C1") {
		t.Fatal("an unselected channel must not bridge")
	}
	if evt, err := client.wrapEvent(ctx, message); evt != nil || err != nil {
		t.Fatalf("a message in an unselected channel must be dropped, got %v, %v", evt, err)
	}

	status, body := f.do(http.MethodPut, "/switchboard/v1/channels/T1/C1?login_id=T1-U1")
	if status != http.StatusOK || body["selected"] != true {
		t.Fatalf("select: HTTP %d %v", status, body)
	}
	if !client.isDMChannel("C1") || client.isDMChannel("C2") {
		t.Error("exactly the selected channel must bridge")
	}
	expectStrings(t, "synced", f.synced, []string{"C1"})
	_, selected := f.list("T1-U1")
	expectStrings(t, "selected after select", selected, []string{"Northwind/#general"})
	var forSync []string
	for _, ch := range client.selectedChannelsForSync(ctx) {
		forSync = append(forSync, ch.ID)
	}
	expectStrings(t, "channels resynced on connect", forSync, []string{"C1"})

	status, body = f.do(http.MethodDelete, "/switchboard/v1/channels/T1/C1?login_id=T1-U1")
	if status != http.StatusOK || body["selected"] != false {
		t.Fatalf("deselect: HTTP %d %v", status, body)
	}
	if client.isDMChannel("C1") {
		t.Error("a deselected channel must stop bridging")
	}
	if evt, err := client.wrapEvent(ctx, message); evt != nil || err != nil {
		t.Errorf("a message in a deselected channel must be dropped, got %v, %v", evt, err)
	}
	if got := client.selectedChannelsForSync(ctx); len(got) != 0 {
		t.Errorf("a deselected channel must not resync on connect: %v", got)
	}
	_, selected = f.list("T1-U1")
	expectStrings(t, "selected after deselect", selected, nil)

	// The other account's selection was never touched.
	if !other.isDMChannel("C2") || !other.switchboardMeta().SwitchboardChannels["C2"] {
		t.Error("the other login's channel must keep bridging")
	}
	if f.saves != 2 {
		t.Errorf("expected one save per change, got %d", f.saves)
	}
}

func TestSwitchboardResyncUsesBootChannelsBeforeFetching(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{
		// C4 was selected while the account was in it; it has left since.
		SwitchboardChannels: map[string]bool{"C1": true, "C2": true, "C4": true, "C999": true},
	})
	// The boot response describes C1 (without is_member, as Slack sends it).
	booted := slack.BootChannel{Channel: *slackChannel("C1", "general", func(ch *slack.Channel) { ch.IsMember = false })}
	client.BootResp.Channels = []slack.BootChannel{booted}
	var fetched []string
	fetch := fetchSwitchboardChannel
	fetchSwitchboardChannel = func(ctx context.Context, s *SlackClient, channelID string) (*slack.Channel, error) {
		fetched = append(fetched, channelID)
		return fetch(ctx, s, channelID)
	}

	var forSync []string
	for _, ch := range client.selectedChannelsForSync(context.Background()) {
		forSync = append(forSync, ch.ID)
	}
	expectStrings(t, "resynced", forSync, []string{"C1", "C2"})
	expectStrings(t, "fetched", fetched, []string{"C2", "C4", "C999"})
}

func TestSwitchboardDMsAlwaysBridge(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})
	client.addDMChannel(f.channels["G1"])

	if !client.isDMChannel("D1") || !client.isDMChannel("G1") {
		t.Error("DMs and group DMs bridge whatever is selected")
	}
}

func TestSwitchboardRejectsChannelsTheAccountIsNotIn(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})

	for _, path := range []string{
		"/switchboard/v1/channels/T1/C4",   // not a member
		"/switchboard/v1/channels/T1/C5",   // archived
		"/switchboard/v1/channels/T1/C999", // unknown
		"/switchboard/v1/channels/T1/D1",   // a DM
		"/switchboard/v1/channels/T1/G1",   // a group DM
		"/switchboard/v1/channels/T2/C1",   // another workspace
	} {
		status, body := f.do(http.MethodPut, path+"?login_id=T1-U1")
		if status != http.StatusNotFound || body["errcode"] != "M_NOT_FOUND" {
			t.Errorf("%s: HTTP %d %v", path, status, body)
		}
	}
	if f.saves != 0 || len(f.synced) != 0 || len(client.switchboardMeta().SwitchboardChannels) != 0 {
		t.Error("a rejected selection must change nothing")
	}
	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/T1/C1?login_id=nobody"); status != http.StatusNotFound {
		t.Errorf("unknown login: HTTP %d", status)
	}
}

func TestSwitchboardSelectAsksSlackNotTheCache(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})
	cache := func(channelID string, isMember bool) {
		stale := *f.channels[channelID]
		stale.IsMember = isMember
		client.chatInfoCache[channelID] = chatInfoCacheEntry{ts: time.Now().Add(-time.Minute), data: &stale}
	}

	// The bridge cached #random while resolving a mention, before the
	// account joined it. The list offers it now, so selecting must work.
	cache("C4", false)
	f.channels["C4"].IsMember = true
	status, body := f.do(http.MethodPut, "/switchboard/v1/channels/T1/C4?login_id=T1-U1")
	if status != http.StatusOK || body["selected"] != true {
		t.Fatalf("select a channel joined since it was cached: HTTP %d %v", status, body)
	}
	if !client.isDMChannel("C4") || f.infoCalls["C4"] != 1 {
		t.Errorf("selected=%v after %d lookups", client.isDMChannel("C4"), f.infoCalls["C4"])
	}
	if !client.chatInfoCache["C4"].data.IsMember {
		t.Error("the fresh answer must replace the cached one")
	}

	// The other way round: cached as joined, but the account has left.
	cache("C1", true)
	f.channels["C1"].IsMember = false
	status, body = f.do(http.MethodPut, "/switchboard/v1/channels/T1/C1?login_id=T1-U1")
	if status != http.StatusNotFound || body["errcode"] != "M_NOT_FOUND" {
		t.Errorf("select a channel left since it was cached: HTTP %d %v", status, body)
	}

	// Slack not answering is a failure, not a refusal, and the cached
	// answer still isn't used.
	cache("C2", true)
	f.slackDown = true
	status, body = f.do(http.MethodPut, "/switchboard/v1/channels/T1/C2?login_id=T1-U1")
	if status != http.StatusBadGateway || body["errcode"] != "M_UNKNOWN" {
		t.Errorf("select while Slack is down: HTTP %d %v", status, body)
	}

	if client.isDMChannel("C1") || client.isDMChannel("C2") || f.saves != 1 {
		t.Errorf("only the confirmed channel may be saved: %v after %d saves",
			client.switchboardMeta().SwitchboardChannels, f.saves)
	}
	expectStrings(t, "synced", f.synced, []string{"C4"})
}

func TestSwitchboardQueuedWorkStopsAfterDeselect(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})
	ctx := context.Background()
	f.channels["C1"].Latest = &slack.Message{Msg: slack.Msg{Timestamp: "1795200000.000100"}}
	channel := f.portal(client, "C1", database.RoomTypeDefault)
	fetch := func(forward bool) *bridgev2.FetchMessagesResponse {
		t.Helper()
		resp, err := client.FetchMessages(ctx, bridgev2.FetchMessagesParams{Portal: channel, Forward: forward, Count: 50})
		if err != nil || resp == nil {
			t.Fatalf("FetchMessages: %v, %v", resp, err)
		}
		return resp
	}

	// Selecting queues the resync that creates the room and fetches its
	// messages. The fixture holds it instead of running it.
	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/T1/C1?login_id=T1-U1"); status != http.StatusOK {
		t.Fatalf("select: HTTP %d", status)
	}
	if len(f.queued) != 1 {
		t.Fatalf("selecting should queue one resync, got %d", len(f.queued))
	}
	resync := f.queued[0]
	if needs, _ := resync.CheckNeedsBackfill(ctx, nil); !resync.ShouldCreatePortal() || !needs {
		t.Fatal("while selected, the queued resync creates the room and fetches messages")
	}
	fetch(true)
	if f.historyCalls["C1"] != 1 {
		t.Fatalf("while selected, messages are fetched: %d requests", f.historyCalls["C1"])
	}

	// The channel is turned off before the queued work runs.
	if status, _ := f.do(http.MethodDelete, "/switchboard/v1/channels/T1/C1?login_id=T1-U1"); status != http.StatusOK {
		t.Fatalf("deselect: HTTP %d", status)
	}
	// A message arrives after that.
	f.history["C1"] = []slack.Message{{Msg: slack.Msg{Timestamp: "1795200060.000200", User: "U2", Text: "after"}}}

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
	if f.historyCalls["C1"] != 1 {
		t.Errorf("a deselected channel must not be fetched: %d requests", f.historyCalls["C1"])
	}

	// Turned off while Slack is answering a fetch that had already begun:
	// what comes back is dropped too.
	if status, _ := f.do(http.MethodPut, "/switchboard/v1/channels/T1/C1?login_id=T1-U1"); status != http.StatusOK {
		t.Fatalf("reselect: HTTP %d", status)
	}
	f.duringHistory = func() {
		if status, _ := f.do(http.MethodDelete, "/switchboard/v1/channels/T1/C1?login_id=T1-U1"); status != http.StatusOK {
			t.Errorf("deselect during fetch: HTTP %d", status)
		}
	}
	if resp := fetch(true); len(resp.Messages) != 0 {
		t.Errorf("a fetch overtaken by the deselect brought in %d messages", len(resp.Messages))
	}
	if f.historyCalls["C1"] != 2 {
		t.Errorf("the overtaken fetch should have reached Slack once: %d requests", f.historyCalls["C1"])
	}
	f.duringHistory = nil

	// DMs and group DMs are fetched whatever is selected, including a group
	// DM the bridge hasn't listed yet.
	for id, roomType := range map[string]database.RoomType{"D1": database.RoomTypeDM, "G1": database.RoomTypeGroupDM} {
		if !client.backfillAllowed(f.portal(client, id, roomType), id) {
			t.Errorf("%s: DMs must keep fetching messages", id)
		}
	}
	dm := &SlackChatResync{
		SlackEventMeta: &SlackEventMeta{PortalKey: networkid.PortalKey{ID: slackid.MakePortalID("T1", "G1")}, CreatePortal: true},
		Client:         client,
		PreFetchedInfo: f.channels["G1"],
	}
	if !dm.ShouldCreatePortal() {
		t.Error("a group DM's resync must still create its room")
	}
}

func TestSwitchboardFailedSaveLeavesSelectionUnchanged(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{
		SwitchboardChannels: map[string]bool{"C2": true},
	})
	f.saveErr = errors.New("database is locked")

	status, body := f.do(http.MethodPut, "/switchboard/v1/channels/T1/C1?login_id=T1-U1")
	if status != http.StatusInternalServerError || body["error"] == nil {
		t.Fatalf("select with failing save: HTTP %d %v", status, body)
	}
	if status, _ = f.do(http.MethodDelete, "/switchboard/v1/channels/T1/C2?login_id=T1-U1"); status != http.StatusInternalServerError {
		t.Fatalf("deselect with failing save: HTTP %d", status)
	}
	if client.isDMChannel("C1") {
		t.Error("an unsaved selection must not bridge")
	}
	if !client.isDMChannel("C2") {
		t.Error("an unsaved deselection must keep bridging")
	}
	_, selected := f.list("T1-U1")
	expectStrings(t, "selected", selected, []string{"Northwind/#Design"})
	if len(f.synced) != 0 {
		t.Error("nothing should sync when the save failed")
	}
}

func TestSwitchboardSeedsSelectionFromChannelsAlreadyBridged(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})
	f.bridged["T1-U1"] = []string{"C2", "C3"}
	ctx := context.Background()

	// Upgrading: what bridged before keeps bridging, and nothing else starts.
	client.seedChannelSelection(ctx)
	_, selected := f.list("T1-U1")
	expectStrings(t, "seeded", selected, []string{"Northwind/#Design", "Northwind/🔒leadership"})
	if client.isDMChannel("C1") {
		t.Error("a channel that wasn't bridged must not start")
	}

	// Seeding happens once: a channel deselected later stays deselected.
	if status, _ := f.do(http.MethodDelete, "/switchboard/v1/channels/T1/C2?login_id=T1-U1"); status != http.StatusOK {
		t.Fatalf("deselect: HTTP %d", status)
	}
	client.seedChannelSelection(ctx)
	_, selected = f.list("T1-U1")
	expectStrings(t, "after reconnect", selected, []string{"Northwind/🔒leadership"})

	// A login with nothing bridged starts with nothing selected.
	fresh := f.addLogin("T2-U9", "T2", "Atlas", true, &slackid.UserLoginMetadata{})
	fresh.seedChannelSelection(ctx)
	if !fresh.switchboardMeta().SwitchboardChannelsSeeded || len(fresh.switchboardMeta().SwitchboardChannels) != 0 {
		t.Errorf("fresh login: %+v", fresh.switchboardMeta())
	}
}

func TestSwitchboardSeedRetriesAfterFailedSave(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", true, &slackid.UserLoginMetadata{})
	f.bridged["T1-U1"] = []string{"C2"}
	ctx := context.Background()

	f.saveErr = errors.New("database is locked")
	client.seedChannelSelection(ctx)
	if client.switchboardMeta().SwitchboardChannelsSeeded {
		t.Fatal("an unsaved seed must not count as done")
	}
	f.saveErr = nil
	client.seedChannelSelection(ctx)
	if !client.isDMChannel("C2") {
		t.Error("the next connection must seed again")
	}
}

func TestSwitchboardWithoutDMOnlyEveryChannelBridges(t *testing.T) {
	f := newSwitchboardFixture(t)
	client := f.addLogin("T1-U1", "T1", "Northwind", false, &slackid.UserLoginMetadata{})

	_, selected := f.list("T1-U1")
	expectStrings(t, "selected", selected, []string{"Northwind/#Design", "Northwind/#general", "Northwind/🔒leadership"})
	if !client.isDMChannel("C1") {
		t.Error("without dm_only upstream bridges every channel")
	}
	status, body := f.do(http.MethodDelete, "/switchboard/v1/channels/T1/C1?login_id=T1-U1")
	if status != http.StatusConflict || body["errcode"] != "SWITCHBOARD_EVERY_CHANNEL_BRIDGED" {
		t.Errorf("deselect without dm_only: HTTP %d %v", status, body)
	}
	if f.saves != 0 {
		t.Error("nothing should be saved")
	}
}

func TestSwitchboardSelectionSurvivesRelogin(t *testing.T) {
	meta := &slackid.UserLoginMetadata{
		Token:                     "old",
		CookieToken:               "old-cookie",
		SwitchboardChannels:       map[string]bool{"C1": true},
		SwitchboardChannelsSeeded: true,
	}
	meta.CopyFrom(&slackid.UserLoginMetadata{Email: "ada@example.org", Token: "new", CookieToken: "new-cookie"})
	if meta.Token != "new" || meta.CookieToken != "new-cookie" || meta.Email != "ada@example.org" {
		t.Errorf("relinking must take the new credentials: %+v", meta)
	}
	if !meta.SwitchboardChannels["C1"] || !meta.SwitchboardChannelsSeeded {
		t.Errorf("relinking must keep the channel selection: %+v", meta)
	}

	// And it round-trips through the database's JSON column.
	data, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	var loaded slackid.UserLoginMetadata
	if err = json.Unmarshal(data, &loaded); err != nil {
		t.Fatal(err)
	}
	if !loaded.SwitchboardChannels["C1"] || !loaded.SwitchboardChannelsSeeded {
		t.Errorf("selection lost in storage: %s", data)
	}
}
