package connector

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/crypto/backup"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/crypto/ssss"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func (mc *MatrixConnector) ValidateConfig() error {
	if mc.Config.PickleKey == "" || mc.Config.PickleKey == "generate" {
		return errors.New("network.pickle_key must be set")
	}
	if mc.Config.DeviceName == "" {
		mc.Config.DeviceName = "Switchboard"
	}
	if mc.Config.MaxMembers <= 0 {
		mc.Config.MaxMembers = 250
	}
	return nil
}

var _ bridgev2.ConfigValidatingNetwork = (*MatrixConnector)(nil)

func (mc *MatrixConnector) LoadUserLogin(ctx context.Context, login *bridgev2.UserLogin) error {
	meta := login.Metadata.(*UserLoginMetadata)
	cli, err := mautrix.NewClient(meta.HomeserverURL, id.UserID(login.ID), meta.AccessToken)
	if err != nil {
		return err
	}
	cli.DeviceID = id.DeviceID(meta.DeviceID)
	cli.Log = login.Log.With().Str("component", "outside matrix").Logger()
	login.Client = &MatrixClient{
		main:   mc,
		login:  login,
		cli:    cli,
		typing: map[id.RoomID]map[id.UserID]bool{},
		spaces: map[id.RoomID]bool{},
	}
	return nil
}

// MatrixClient is one outside account: its client, end-to-end crypto and
// sync loop.
type MatrixClient struct {
	main   *MatrixConnector
	login  *bridgev2.UserLogin
	cli    *mautrix.Client
	crypto *cryptohelper.CryptoHelper

	setup     sync.Once
	cancel    context.CancelFunc
	cancelMu  sync.Mutex
	connected bool

	stateMu sync.Mutex
	// Who was typing in each room at the last typing event.
	typing map[id.RoomID]map[id.UserID]bool
	// Rooms that are spaces, which aren't chats.
	spaces map[id.RoomID]bool
	// Room -> the other user, from the account's m.direct.
	direct map[id.RoomID]id.UserID
}

var (
	_ bridgev2.NetworkAPI = (*MatrixClient)(nil)
)

// initCrypto sets up end-to-end encryption for this account, keeping its
// keys in the bridge's database under the login's ID.
func (mc *MatrixClient) initCrypto(ctx context.Context) error {
	if mc.crypto != nil {
		return nil
	}
	pickle := sha256.Sum256([]byte("switchboard-matrix:" + mc.main.Config.PickleKey))
	helper, err := cryptohelper.NewCryptoHelper(mc.cli, pickle[:], mc.main.Bridge.DB.Database)
	if err != nil {
		return err
	}
	helper.DBAccountID = string(mc.login.ID)
	if err = helper.Init(ctx); err != nil {
		return err
	}
	mc.crypto = helper
	mc.cli.Crypto = helper
	return nil
}

// verifyWithRecoveryKey cross-signs this device with the account's
// recovery key, so other clients trust it and share keys with it, then
// restores the server-side key backup in the background for history.
func (mc *MatrixClient) verifyWithRecoveryKey(ctx context.Context, recoveryKey string) error {
	mach := mc.crypto.Machine()
	keyID, keyData, err := mach.SSSS.GetDefaultKeyData(ctx)
	if err != nil {
		return fmt.Errorf("the account has no recovery set up: %w", err)
	}
	key, err := keyData.VerifyRecoveryKey(keyID, recoveryKey)
	if err != nil && !errors.Is(err, ssss.ErrUnverifiableKey) {
		return err
	}
	if err = mach.FetchCrossSigningKeysFromSSSS(ctx, key); err != nil {
		return fmt.Errorf("couldn't fetch cross-signing keys: %w", err)
	}
	if err = mach.SignOwnDevice(ctx, mach.OwnIdentity()); err != nil {
		return fmt.Errorf("couldn't sign this session: %w", err)
	}
	if err = mach.SignOwnMasterKey(ctx); err != nil {
		return fmt.Errorf("couldn't sign the master key: %w", err)
	}
	mc.login.Metadata.(*UserLoginMetadata).Verified = true
	if err = mc.login.Save(ctx); err != nil {
		return err
	}
	raw, err := mach.SSSS.GetDecryptedAccountData(ctx, event.AccountDataMegolmBackupKey, key)
	if err != nil {
		zerolog.Ctx(ctx).Warn().Err(err).Msg("No key backup key in secret storage")
		return nil
	}
	backupKey, err := backup.MegolmBackupKeyFromBytes(raw)
	if err != nil {
		zerolog.Ctx(ctx).Warn().Err(err).Msg("Bad key backup key")
		return nil
	}
	go func() {
		bctx := mc.login.Log.WithContext(context.Background())
		version, err := mach.DownloadAndStoreLatestKeyBackup(bctx, backupKey)
		if err != nil {
			mc.login.Log.Warn().Err(err).Msg("Couldn't restore the key backup")
		} else {
			mc.login.Log.Info().Str("version", string(version)).Msg("Restored the key backup")
		}
	}()
	return nil
}

func (mc *MatrixClient) Connect(ctx context.Context) {
	log := mc.login.Log.With().Str("action", "connect").Logger()
	ctx = log.WithContext(ctx)
	mc.login.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnecting})
	if _, err := mc.cli.Versions(ctx); err != nil {
		log.Warn().Err(err).Msg("Couldn't reach the homeserver")
	}
	if _, err := mc.cli.Whoami(ctx); err != nil {
		if errors.Is(err, mautrix.MUnknownToken) {
			mc.badCredentials("This session was signed out. Sign in again.")
			return
		}
		log.Warn().Err(err).Msg("Whoami failed, trying to sync anyway")
	}
	if err := mc.initCrypto(ctx); err != nil {
		log.Err(err).Msg("Couldn't set up encryption")
		mc.login.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateUnknownError,
			Error:      "matrix-crypto-failed",
			Message:    "Couldn't set up encryption: " + err.Error(),
		})
		return
	}
	mc.setup.Do(mc.registerHandlers)
	mc.loadDirect(ctx)

	loopCtx, cancel := context.WithCancel(mc.login.Log.WithContext(context.Background()))
	mc.cancelMu.Lock()
	if mc.cancel != nil {
		mc.cancel()
	}
	mc.cancel = cancel
	mc.cancelMu.Unlock()
	go mc.syncLoop(loopCtx)
}

func (mc *MatrixClient) badCredentials(message string) {
	mc.login.BridgeState.Send(status.BridgeState{
		StateEvent: status.StateBadCredentials,
		Error:      "matrix-signed-out",
		Message:    message,
	})
}

// syncLoop keeps a /sync running, reconnecting with backoff.
func (mc *MatrixClient) syncLoop(ctx context.Context) {
	log := zerolog.Ctx(ctx)
	backoff := 2 * time.Second
	for {
		err := mc.cli.SyncWithContext(ctx)
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, mautrix.MUnknownToken) {
			mc.badCredentials("This session was signed out. Sign in again.")
			return
		}
		mc.connected = false
		log.Warn().Err(err).Dur("retry_in", backoff).Msg("Sync stopped")
		mc.login.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateTransientDisconnect,
			Error:      "matrix-sync-failed",
			Message:    "Can't reach the homeserver",
		})
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 2*time.Minute)
	}
}

func (mc *MatrixClient) Disconnect() {
	mc.cancelMu.Lock()
	if mc.cancel != nil {
		mc.cancel()
		mc.cancel = nil
	}
	mc.cancelMu.Unlock()
	mc.cli.StopSync()
}

func (mc *MatrixClient) IsLoggedIn() bool {
	return mc.cli.AccessToken != ""
}

func (mc *MatrixClient) LogoutRemote(ctx context.Context) {
	if _, err := mc.cli.Logout(ctx); err != nil {
		zerolog.Ctx(ctx).Warn().Err(err).Msg("Couldn't sign the outside session out")
	}
	mc.cli.AccessToken = ""
}

func (mc *MatrixClient) IsThisUser(ctx context.Context, userID networkid.UserID) bool {
	return remoteUserID(userID) == mc.cli.UserID
}

// loadDirect reads the account's m.direct, which says which rooms are DMs.
func (mc *MatrixClient) loadDirect(ctx context.Context) {
	var content event.DirectChatsEventContent
	if err := mc.cli.GetAccountData(ctx, event.AccountDataDirectChats.Type, &content); err != nil {
		zerolog.Ctx(ctx).Debug().Err(err).Msg("No m.direct")
	}
	mc.setDirect(content)
}

func (mc *MatrixClient) setDirect(content event.DirectChatsEventContent) {
	direct := map[id.RoomID]id.UserID{}
	for user, rooms := range content {
		for _, room := range rooms {
			direct[room] = user
		}
	}
	mc.stateMu.Lock()
	mc.direct = direct
	mc.stateMu.Unlock()
}

func (mc *MatrixClient) dmPartner(room id.RoomID) (id.UserID, bool) {
	mc.stateMu.Lock()
	defer mc.stateMu.Unlock()
	u, ok := mc.direct[room]
	return u, ok
}

func (mc *MatrixClient) isSpace(room id.RoomID) bool {
	mc.stateMu.Lock()
	defer mc.stateMu.Unlock()
	return mc.spaces[room]
}
