package connector

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/rs/zerolog"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/status"
)

const (
	flowPassword = "password"
	flowToken    = "token"

	stepCredentials = "app.switchboard.matrix.credentials"
	stepRecoveryKey = "app.switchboard.matrix.recovery_key"
	stepComplete    = "app.switchboard.matrix.complete"
)

func (mc *MatrixConnector) GetLoginFlows() []bridgev2.LoginFlow {
	return []bridgev2.LoginFlow{{
		Name:        "Password",
		Description: "Sign in with your Matrix username and password.",
		ID:          flowPassword,
	}, {
		Name:        "Access token",
		Description: "For accounts that sign in with a single sign-on provider: paste an access token from Element (Settings, Help & About).",
		ID:          flowToken,
	}}
}

func (mc *MatrixConnector) CreateLogin(ctx context.Context, user *bridgev2.User, flowID string) (bridgev2.LoginProcess, error) {
	switch flowID {
	case flowPassword, flowToken:
		return &Login{main: mc, user: user, flow: flowID}, nil
	default:
		return nil, bridgev2.ErrInvalidLoginFlowID
	}
}

// Login signs in to an outside homeserver, then optionally takes the
// account's recovery key so this device is verified and can read history.
type Login struct {
	main  *MatrixConnector
	user  *bridgev2.User
	flow  string
	login *bridgev2.UserLogin
}

var _ bridgev2.LoginProcessUserInput = (*Login)(nil)

func (l *Login) Start(ctx context.Context) (*bridgev2.LoginStep, error) {
	fields := []bridgev2.LoginInputDataField{{
		Type:         bridgev2.LoginInputFieldTypeDomain,
		ID:           "homeserver",
		Name:         "Homeserver",
		Description:  "Your account's server, such as matrix.org.",
		DefaultValue: "matrix.org",
	}}
	if l.flow == flowPassword {
		fields = append(fields, bridgev2.LoginInputDataField{
			Type:        bridgev2.LoginInputFieldTypeUsername,
			ID:          "username",
			Name:        "Username",
			Description: "Your Matrix ID, like @you:matrix.org, or just the name before the colon.",
		}, bridgev2.LoginInputDataField{
			Type: bridgev2.LoginInputFieldTypePassword,
			ID:   "password",
			Name: "Password",
		})
	} else {
		fields = append(fields, bridgev2.LoginInputDataField{
			Type: bridgev2.LoginInputFieldTypeToken,
			ID:   "token",
			Name: "Access token",
		})
	}
	return &bridgev2.LoginStep{
		Type:            bridgev2.LoginStepTypeUserInput,
		StepID:          stepCredentials,
		Instructions:    "Sign in to your Matrix account. Switchboard joins it as a new session.",
		UserInputParams: &bridgev2.LoginUserInputParams{Fields: fields},
	}, nil
}

func (l *Login) Cancel() {}

func (l *Login) SubmitUserInput(ctx context.Context, input map[string]string) (*bridgev2.LoginStep, error) {
	if l.login == nil {
		return l.signIn(ctx, input)
	}
	return l.recover(ctx, strings.TrimSpace(input["recovery_key"]))
}

// resolveHomeserver turns a server name into its client API URL through
// .well-known, or takes a URL as given.
func resolveHomeserver(ctx context.Context, server string) (string, error) {
	server = strings.TrimSpace(server)
	if server == "" {
		return "", errors.New("enter a homeserver")
	}
	if strings.Contains(server, "://") {
		return strings.TrimRight(server, "/"), nil
	}
	wk, err := mautrix.DiscoverClientAPI(ctx, server)
	if err != nil {
		zerolog.Ctx(ctx).Debug().Err(err).Str("server", server).Msg("No usable .well-known, trying the name itself")
	}
	if wk != nil && wk.Homeserver.BaseURL != "" {
		return strings.TrimRight(wk.Homeserver.BaseURL, "/"), nil
	}
	return "https://" + server, nil
}

func (l *Login) signIn(ctx context.Context, input map[string]string) (*bridgev2.LoginStep, error) {
	base, err := resolveHomeserver(ctx, input["homeserver"])
	if err != nil {
		return nil, err
	}
	cli, err := mautrix.NewClient(base, "", "")
	if err != nil {
		return nil, fmt.Errorf("bad homeserver address: %w", err)
	}
	if l.flow == flowPassword {
		username := strings.TrimSpace(input["username"])
		_, err = cli.Login(ctx, &mautrix.ReqLogin{
			Type:                     mautrix.AuthTypePassword,
			Identifier:               mautrix.UserIdentifier{Type: mautrix.IdentifierTypeUser, User: username},
			Password:                 input["password"],
			InitialDeviceDisplayName: l.main.Config.DeviceName,
			StoreCredentials:         true,
		})
		if errors.Is(err, mautrix.MForbidden) {
			return nil, errors.New("wrong username or password")
		} else if err != nil {
			return nil, fmt.Errorf("couldn't sign in: %w", err)
		}
	} else {
		cli.AccessToken = strings.TrimSpace(input["token"])
		who, err := cli.Whoami(ctx)
		if err != nil {
			return nil, fmt.Errorf("that token didn't work: %w", err)
		} else if who.DeviceID == "" {
			return nil, errors.New("the server didn't say which session that token belongs to")
		}
		cli.UserID, cli.DeviceID = who.UserID, who.DeviceID
	}

	profile, _ := cli.GetProfile(ctx, cli.UserID)
	name := cli.UserID.String()
	if profile != nil && profile.DisplayName != "" {
		name = profile.DisplayName
	}
	ul, err := l.user.NewLogin(ctx, &database.UserLogin{
		ID:         makeLoginID(cli.UserID),
		RemoteName: name,
		RemoteProfile: status.RemoteProfile{
			Name:     name,
			Username: cli.UserID.String(),
		},
		Metadata: &UserLoginMetadata{
			HomeserverURL: base,
			AccessToken:   cli.AccessToken,
			DeviceID:      cli.DeviceID.String(),
		},
	}, &bridgev2.NewLoginParams{DeleteOnConflict: true})
	if err != nil {
		return nil, fmt.Errorf("couldn't save the login: %w", err)
	}
	l.login = ul
	mcli := ul.Client.(*MatrixClient)
	if err = mcli.initCrypto(ctx); err != nil {
		zerolog.Ctx(ctx).Err(err).Msg("Couldn't set up encryption for the new login")
		return l.complete(ctx), nil
	}
	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeUserInput,
		StepID:       stepRecoveryKey,
		Instructions: "To read encrypted chats, including past messages, enter your account's recovery key (Element calls it a Security Key). You can skip this, but encrypted chats may not show.",
		UserInputParams: &bridgev2.LoginUserInputParams{Fields: []bridgev2.LoginInputDataField{{
			Type:     bridgev2.LoginInputFieldTypePassword,
			ID:       "recovery_key",
			Name:     "Recovery key",
			Optional: true,
		}}},
	}, nil
}

func (l *Login) recover(ctx context.Context, key string) (*bridgev2.LoginStep, error) {
	if key == "" {
		return l.complete(ctx), nil
	}
	mcli := l.login.Client.(*MatrixClient)
	if err := mcli.verifyWithRecoveryKey(ctx, key); err != nil {
		return nil, fmt.Errorf("that recovery key didn't work: %w", err)
	}
	return l.complete(ctx), nil
}

func (l *Login) complete(ctx context.Context) *bridgev2.LoginStep {
	go l.login.Client.Connect(l.login.Log.WithContext(context.Background()))
	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeComplete,
		StepID:       stepComplete,
		Instructions: fmt.Sprintf("Signed in as %s", l.login.RemoteName),
		CompleteParams: &bridgev2.LoginCompleteParams{
			UserLoginID: l.login.ID,
			UserLogin:   l.login,
		},
	}
}
