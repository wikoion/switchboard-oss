# Switchboard: self-hosted alternative to Beeper — spec

Oct 24, 2026 · Richard Draycott

> This file is the tracked copy of the spec, written in October 2026. Change it here, through normal commits.

## Summary and goals

Switchboard is an alternative to Beeper made of two things you own. The first is a private Matrix homeserver plus one bridge per chat network, run by Docker Compose on an always-on host on your tailnet. The second is one Flutter app for iOS, Android, macOS and Linux that puts every network in one inbox. No Beeper account and no third-party cloud sits in the message path.

**Goals**

- Replace your daily Beeper use on iPhone, Mac and Linux, and on Android if you use it, without losing any feature you use day to day.
- One command (`sb up`) builds the whole backend from nothing: it creates secrets, configs, appservice registrations and databases.
- Link, relink and unlink network accounts from inside the app on any device: QR pairing, phone code, cookie login or token. A link made on one device works on all of them, because the session lives on the server.
- The backend runs unattended for weeks on an always-on host. It restarts itself, alerts you when a bridge loses its login, and backs up nightly.

**Non-goals for v1**

- Hosting other people. It is single-user by design, though nothing stops a second account later.
- Federation with the public Matrix network. Outside Matrix accounts (matrix.org and others) are bridged instead, like any other network; see the Bridge catalogue.
- Voice and video calls. Beeper doesn't bridge calls either.
- A web client.

**Success criteria**

- Every network in the bridge catalogue sends and receives text, media, reactions, replies and read receipts.
- An incoming message shows in the app within 5 s of arriving in the native app, on Wi-Fi or LTE.
- A cold start shows the chat list in under 1.5 s with 2,000 rooms.
- The backend comes back by itself after a host reboot or a Docker update, with no manual steps.
- A restore from backup onto a clean Docker install takes under 30 minutes and keeps every network linked.

## Key decisions

Switchboard uses the same engine as Beeper: Matrix plus the mautrix bridges. Beeper offers those bridges as a service ([mautrix docs](https://docs.mau.fi/bridges/)). What changes is who hosts them and which client you use.

| Area | Choice | Why | Rejected |
| --- | --- | --- | --- |
| Bridges | mautrix bridges on bridgev2, pinned monthly tags (`v26.10` today) | They are Beeper's own bridges, released monthly with one shared login API | Building our own bridges |
| Homeserver | Synapse + Postgres 18 | It supports the appservice features the bridges need, built-in simplified sliding sync, and Postgres full-text search across all rooms | Tuwunel/conduwuit: lighter, but less tested with bridges. Beeper's hungryserv isn't open source |
| Orchestration | Docker Compose (Docker Desktop on macOS, Docker Engine on Linux), driven by an `sb` CLI | Each bridge is a container, and the stack moves between a Mac and a Linux host unchanged | matrix-docker-ansible-deploy: built for Linux servers over SSH. It stays a reference for configs |
| Remote access | A Tailscale sidecar container that joins your tailnet as its own node, `switchboard`, using Tailscale Serve for HTTPS | Nothing is exposed publicly. The URL survives moving the stack to another host | Public reverse proxy or Funnel |
| Server name | `switchboard.internal`, with federation off | `.internal` is reserved for private use. A server name can't change later, so it must not depend on a hostname | The tailnet hostname |
| Encryption | Portal rooms unencrypted by default | Every hop is already yours: WireGuard and TLS in transit, the host's disk encryption at rest. Leaving them unencrypted enables server-side search and server-side scheduled sends, and removes device verification. You can turn it on per bridge | End-to-bridge encryption as Beeper does it. That suits a cloud host, not your own machine |
| Client | Flutter UI over a Rust core built on matrix-rust-sdk, bound with flutter\_rust\_bridge | One codebase for 4 platforms. matrix-rust-sdk is the engine behind Element X: room list service, timeline, offline send queue, local cache | Tauri: weaker mobile push and webview cookie access. React Native: no Linux. famedly's Dart SDK: kept as the fallback |
| Bridge control | A small Go service, the Hub, in front of every bridge's provisioning API, plus bridge-state tracking and a scheduler | The app gets one API for linking accounts, health, reminders and send-later | Calling each bridge directly from the app |
| Push | Sygnal to APNs for iOS, ntfy (UnifiedPush) for Android, a live sync connection on desktop | All three self-hosted in the same stack | Firebase-only |

**Decisions for you**

1. **Apple Developer Program, $99/year.** Free personal-team builds expire after 7 days and can't use push notifications. Decided 24 October 2026: build and test now without iOS push, and buy the licence later. Until then, iOS uses free 7-day builds and ntfy-app alerts (see Notifications).
2. **Which networks to switch on.** The default set is WhatsApp, Signal, Telegram, Messenger, Instagram, X, LinkedIn, Discord and Slack. Google Messages only matters if you carry an Android phone. iMessage is optional.
3. **Encryption default.** Unencrypted portal rooms, as argued above. Say if you want end-to-bridge encryption instead; it costs server-side search.
4. **Backup destination.** An external drive, a NAS, or an offsite bucket such as Backblaze B2.
5. **Platform order.** Decided 30 October 2026: iOS first, then the Linux desktop app, with macOS and Android after that.

## System architecture

Every device enters through one tailnet node. Caddy routes Matrix traffic to Synapse and control traffic to the Hub, and the bridges are the only containers that talk to the chat networks.

![Switchboard architecture · 4 clients, 8 services, 2 external systems](img/architecture.png)

An incoming WhatsApp message travels like this. The bridge receives it and posts it into Synapse as that contact's ghost user. Synapse then pushes to phones through the gateways and streams it to open apps over sliding sync. A reply goes the other way, app to Synapse to bridge to WhatsApp, and the bridge posts a send-status event that becomes the delivery tick.

## Backend stack

The backend is one Compose project, `switchboard`, of about 9 core containers plus one container per enabled bridge. It is designed for an always-on Mac or Linux machine that can give Docker at least 8 GB of memory (Docker Desktop on macOS, Docker Engine on Linux). All images are multi-arch, so they run natively on arm64 and x86_64.

| Service | Image | Role | Reachable from |
| --- | --- | --- | --- |
| `tailscale` | `tailscale/tailscale:stable` | Joins the tailnet as node `switchboard`. Tailscale Serve terminates HTTPS on 443 with a `*.ts.net` certificate and proxies to Caddy | Your tailnet only |
| `caddy` | `caddy:2` | Routes `/_matrix/*` and `/_synapse/client/*` to Synapse and `/_switchboard/*` to the Hub. Serves `/.well-known/matrix/client`. Blocks `/_synapse/admin` | `tailscale` |
| `postgres` | `postgres:18-alpine` | One cluster with a database each for Synapse (C collation), every bridge and the Hub | Internal network |
| `synapse` | `matrixdotorg/synapse` (pinned) | Homeserver. Registration closed, federation off, appservice registrations mounted from `./appservices/` | Caddy, bridges, Hub |
| `hub` | built locally from `./hub` (Go) | Control plane: bridge registry, login proxy, bridge state, scheduler, alerts | Caddy |
| `socket-proxy` | `tecnativa/docker-socket-proxy` | Gives the Hub container listing, logs and restart, and nothing else | Hub |
| `ntfy` | `binwiederhier/ntfy` | UnifiedPush and Matrix push gateway for Android, and the iOS fallback | Synapse, tailnet |
| `sygnal` | `matrixdotorg/sygnal` | APNs push gateway for iOS. Compose profile `ios-push`, only with a paid Apple account | Synapse |
| `backup` | built locally (restic + pg client) | One-shot job: `pg_dump`, media and secrets into a restic repo | Run by launchd |
| `mautrix-*` | `dock.mau.dev/mautrix/<bridge>:vYY.MM` | One container per enabled bridge (see Bridge catalogue) | Synapse, Hub |

**Layout rules**

- `compose.yaml` holds the core services. `sb` generates `compose.bridges.yml` from the enabled bridges. `.env` sets `COMPOSE_FILE=compose.yaml:compose.bridges.yml`, so plain `docker compose ps` and `logs` work.
- Postgres data and Synapse media live in named volumes inside the Docker VM, not bind mounts. Bind-mounted Postgres on macOS is slow and has fsync and permission problems. Rendered configs are bind-mounted read-only from `./config/`.
- Nothing publishes a host port except Synapse on `127.0.0.1:8008` for local debugging. Devices, including the host itself, use the tailnet URL `https://switchboard.<tailnet>.ts.net`.
- Every service has `restart: unless-stopped` and a healthcheck: Synapse `/health`, Postgres `pg_isready`, bridges `/_matrix/mau/ready`. `depends_on` with `service_healthy` orders startup Postgres, then Synapse, then bridges and the Hub.
- Docker Desktop VM sizing: 4 CPUs, 8 GB RAM, 128 GB disk. The expected steady state is roughly 3 GB RAM: Synapse about 1 GB, Postgres 0.5 GB, and 50–200 MB per bridge. These figures are estimates; measure them in M0.
- The iMessage bridge, if enabled, runs natively on macOS under launchd, not in Docker, because it needs Messages.app and Full Disk Access. It reaches Synapse through a `mautrix-wsproxy` container.

## Bridge catalogue

The default set covers 9 networks that work today on maintained bridges, plus Matrix itself. Four more are available but off by default. Every bridge except Google Chat uses the bridgev2 login API, so the app links them all through one generic flow. Every bridgev2 bridge takes several logins per user, so one network can have several accounts (two WhatsApp numbers, say).

| Network | Bridge and image | Login flows | Default | Notes |
| --- | --- | --- | --- | --- |
| WhatsApp | mautrix-whatsapp, `dock.mau.dev/mautrix/whatsapp` | QR, phone pairing code, passkey | On | Runs as a linked device. WhatsApp logs out linked devices if the phone is inactive for about 14 days. Passkey login added in [July 2026](https://mau.fi/blog/2026-07-mautrix-release/) |
| Signal | mautrix-signal, `…/signal` | QR (link as secondary device) | On | Accounts without a phone number and username chats supported from [October 2026](https://mau.fi/blog/2026-10-mautrix-release/) |
| Telegram | mautrix-telegram (Go rewrite), `…/telegram` | Phone + code + 2FA password, or QR | On | Go rewrite released [April 2026](https://mau.fi/blog/2026-04-mautrix-release/), with topic groups. Needs an `api_id`/`api_hash` from my.telegram.org. Use Postgres: the legacy SQLite migration had a corruption bug |
| Messenger | mautrix-meta, `…/meta` | Cookies (webview login) | On | Encrypted history backfill asks for your backup PIN after login (October 2026) |
| Instagram | mautrix-instagram, `…/meta:ig-vYY.MM` | Cookies, or username and password (`android` flow) | On | A separate bridge since Instagram changed its DM protocol in July 2026 |
| X | mautrix-twitter, `…/twitter` | Cookies | On | XChat support added [March 2026](https://mau.fi/blog/2026-03-mautrix-release/) |
| LinkedIn | mautrix-linkedin, `…/linkedin` | Cookies | On | On the same monthly release train since April 2026 |
| Slack | mautrix-slack at a pinned tag, patched and built locally from `bridges/slack` | Cookies or token | On | Full direct media from October 2026. DMs always bridge; channels are chosen one by one in Settings |
| Discord | mautrix-discord bridgev2 rewrite (branch `megadiscord`) at a pinned commit, patched and built locally from `bridges/discord` | Browser (cookies), QR from the Discord app, token, or email or phone and password with 2FA | On | Switched from the legacy v0.7 bridge on 31 Oct 2026: the rewrite is under active development and links through the same login API as the rest. Move to monthly tags when it gets them. DMs always bridge; channels are chosen one by one in Settings |
| Matrix | `sb-matrix`, Switchboard's own bridgev2 connector in `bridges/matrix`, built locally | Homeserver, username and password, or an access token; then the account's recovery key (optional) | On | Signs in to outside Matrix accounts as a new session and mirrors their rooms here, since this server can't federate. End-to-end encrypted rooms work once the recovery key has verified the session; it also restores the key backup for history. Invites are accepted automatically |
| Google Messages | mautrix-gmessages, `…/gmessages` | QR, or Google account (cookies + emoji confirm) | Off | Only useful with an Android phone for SMS and RCS |
| Bluesky | mautrix-bluesky, `…/bluesky` | Handle + app password | Off | Released December 2024 |
| Google Voice | mautrix-gvoice, `…/gvoice` | Cookies | Off | US numbers only |
| Google Chat | mautrix-googlechat (legacy Python) | Cookies, through bot commands | Off | Absent from 2026 release notes, so maintenance is uncertain |
| iMessage | mautrix-imessage, `mac` connector, native under launchd | Signs in as the Mac's Apple ID | Off (M3) | A normal Mac gives basic bridging: AppleScript send, `chat.db` read. Full features need SIP disabled, which isn't recommended. A RustPush-based bridge ([jasonlaguidice/imessage](https://github.com/jasonlaguidice/imessage), v0.0.1) is early and worth watching |
| LINE | none | — | Out of scope | Beeper offers LINE through its own cloud only. No maintained self-hosted bridge exists |

mautrix bridges release on the 16th of each month as `vYY.MM` tags. The bridges sharing a release are pinned together in `versions.env` (see Automation).

## Automation and operations

One Go binary, `sb`, owns the whole lifecycle. It shares code with the Hub, and every command is idempotent and safe to rerun. You never hand-edit a bridge config or registration file.

| Command | What it does |
| --- | --- |
| `sb init` | Checks prerequisites (Docker Desktop running, at least 8 GB allocated, Tailscale auth key). Asks for your username and networks. Generates `secrets/`: Postgres passwords, appservice tokens, Synapse signing key and secrets. Renders all configs, creates your admin user, and prints a device-setup QR with the homeserver URL and username |
| `sb up` / `sb down` | Starts the stack and waits for every healthcheck, or stops it |
| `sb enable <bridge>` / `sb disable <bridge>` | Renders the bridge config and registration, creates its database, restarts Synapse (10–15 s outage, because Synapse only reads registrations at startup) and starts the bridge. `disable` keeps the database unless you pass `--purge` |
| `sb status` | Services, versions, login state per account, last backup, disk use |
| `sb doctor` | Deep checks: an appservice ping per bridge (`POST /_matrix/client/v1/appservice/{id}/ping`), tailnet reachability, certificate expiry, database size, and a round-trip message test |
| `sb update [--check]` | Compares pinned tags with upstream. Then backs up, pulls, recreates one service at a time and health-checks. On failure it restores the previous tag and the pre-update backup |
| `sb backup` / `sb restore <snapshot>` | See Backups below |
| `sb logs <svc>` / `sb shell <svc>` | Thin wrappers over Compose |

**Config generation, per bridge**

1. `bridges.yaml` is the catalogue. Each entry has the bridge id, image, port, bot localpart, ghost-user prefix (`whatsapp_`), database name and an overlay file.
2. `sb` runs the pinned image once on an empty `/data`. The bridge writes its example `config.yaml` and exits.
3. It deep-merges the shared overlay (below) and the bridge's own overlay into that example. Any overlay key missing from the example is a hard error, which catches settings renamed upstream.
4. It renders `registration.yaml` from the same secrets: id, url, `as_token`, `hs_token`, `sender_localpart`, an exclusive user namespace `@<prefix>.*:switchboard.internal`, `rate_limited: false` and `receive_ephemeral: true`.
5. It writes the file to `./appservices/<id>.yaml`, regenerates Synapse's `app_service_config_files` list, creates the database, restarts Synapse, then starts the bridge and waits for `/_matrix/mau/ready` and a successful ping.

Shared overlay (bridgev2 key names as of `v26.10`; step 3 enforces them):

```yaml
homeserver:
  address: http://synapse:8008
  domain: switchboard.internal
  software: standard
  status_endpoint: http://hub:8090/internal/bridge-state/{id}
  message_send_checkpoint_endpoint: http://hub:8090/internal/checkpoint/{id}
appservice:
  address: http://mautrix-{id}:{port}
  as_token: ${AS_TOKEN}
  hs_token: ${HS_TOKEN}
database:
  type: postgres
  uri: postgres://{id}:${DB_PASSWORD}@postgres/{id}?sslmode=disable
bridge:
  permissions:
    "@alice:switchboard.internal": admin
  personal_filtering_spaces: true
matrix:
  message_status_events: true
  delivery_receipts: true
provisioning:
  shared_secret: ${PROVISIONING_SECRET}
double_puppet:
  secrets:
    switchboard.internal: as_token:${DOUBLEPUPPET_AS_TOKEN}
backfill:
  enabled: true
encryption:
  allow: false
```

**Double puppeting and the Hub's identity.** `appservices/doublepuppet.yaml` has `url: null` and a non-exclusive namespace on your user only. All bridges share its token, so a message you send from the WhatsApp app on your phone shows as you, not as a ghost user. The Hub has its own registration (`hub.yaml`) with the same non-exclusive namespace. It uses that to send scheduled messages and write account data as you.

**Synapse essentials.** `public_baseurl` is the tailnet URL. Registration is disabled. There is no federation listener and `federation_domain_whitelist: []`. Upload limit is 100 MB, URL previews are on, presence is off, and push uses `include_content: false`. If you turn bridge encryption on, its default mode needs no Synapse flags. Only the sync-less appservice mode needs Synapse 1.141 or later plus the MSC3202 and MSC2409 flags, and mautrix doesn't recommend it ([mautrix docs](https://docs.mau.fi/bridges/general/end-to-bridge-encryption.html)).

**Updates.** Bridges are updated monthly, 3 days after the 16th, to let others hit regressions first. The Hub runs `sb update --check` weekly and posts what is available to your System room. Synapse is updated every other release.

**Backups.** A launchd agent runs `docker compose run --rm backup` at 03:30 nightly. It takes a `pg_dump -Fc` of each database, the Synapse media volume, `secrets/`, `config/`, `appservices/`, `bridges.yaml`, `switchboard.yaml` (git-ignored) and `versions.env`, and stores them in a restic repo. The repo password lives in the macOS Keychain. Retention is 7 daily, 4 weekly and 6 monthly snapshots, and the result posts to the System room. A quarterly drill, `sb restore --scratch`, restores into a separate Compose project and checks the databases and Synapse. Bridges stay stopped there, so they don't fight the live sessions.

**Mac host setup (one-time; `sb doctor` checks it)**

- Disable sleep, so that `pmset -g` shows `SleepDisabled 1`, and add `pmset -a autorestart 1` so the Mac powers back on after an outage.
- Docker Desktop: start at login, and turn off automatic updates, because an update restarts the VM.
- macOS: turn off automatic install of OS updates. After a reboot, FileVault needs someone to unlock the Mac before anything starts.
- FileVault has no software fix for unplanned power loss; a small UPS covers short cuts. For planned remote restarts use `sudo fdesetup authrestart`.
- Turn on Tailscale SSH on the Mac so you can run `sb` from your phone when you're away from it.

## Control plane: the Hub

The Hub is a Go service of about 2,000 lines that gives the app one API for everything Matrix itself doesn't cover. That means linking accounts, bridge health, send-later, reminders and system status. It reuses mautrix-go's provisioning types and keeps its state in its own Postgres database.

**Auth.** The app sends its normal Matrix access token. The Hub checks it with Synapse's `/account/whoami`, caches the result for 5 minutes, and allows only the owner account. It passes the same token through to the bridges, which accept Matrix access tokens from local users on every provisioning call ([spec](https://github.com/mautrix/go/blob/main/bridgev2/matrix/provisioning.yaml)).

| Method | Path under `/_switchboard/v1` | Purpose |
| --- | --- | --- |
| GET | `/bridges` | Every enabled bridge: network name, icon, version, container health, bridge state, and its logins (remote name, avatar, state, last error). Combined from each bridge's `/v3/whoami` and pushed bridge state |
| any | `/bridges/{id}/provision/v3/*` | Transparent proxy to that bridge's provisioning API: login flows and steps, logout, contacts, user search, identifier lookup, create DM, create group |
| POST | `/bridges/{id}/restart` | Restarts the container through the socket proxy |
| GET | `/events` | Server-sent events: bridge-state changes and backfill progress, for the Accounts screen |
| POST | `/contacts/search` | Fans one query out to every bridge's `search_users` and `contacts`, then merges and de-duplicates the results for New Chat |
| GET, POST, DELETE | `/scheduled` | Send-later items: room, message content (including reply relation), `send_at`, transaction id |
| GET, POST, DELETE | `/reminders` | Chat reminders: room, `remind_at`, optional note, archive-now flag |
| GET | `/system` | Backup result, available updates, disk use, versions |

**Internal endpoints** (reachable only on the Compose network)

- `POST /internal/bridge-state/{id}` receives each bridge's state pushes: `CONNECTING`, `CONNECTED`, `TRANSIENT_DISCONNECT`, `BAD_CREDENTIALS`, `LOGGED_OUT`, `UNKNOWN_ERROR`. If `BAD_CREDENTIALS` or `LOGGED_OUT` lasts over 2 minutes, the Hub posts an alert to your System room, for example "WhatsApp needs relinking", with a `switchboard://accounts/whatsapp/<login>` link.
- `POST /internal/checkpoint/{id}` records message-send checkpoints. The app's "Why didn't this send?" sheet reads them.

**Scheduler.** It wakes every 15 s, so jobs fire within 15 s of their due time.

- *Send later*: the Hub sends as you through its appservice identity, reusing the stored transaction id so a retry can't double-send. It makes 3 attempts with backoff, then marks the item failed and alerts you.
- *Reminders*: the Hub clears the chat's archive state, writes `app.switchboard.reminder` room account data with `fired_ts` and the note, and posts a notice with a link to the chat in the System room. That notice reaches every device as a normal push.
- Both work while every device is offline. That is why they live on the server and not in the app.
- With encryption on for a bridge, send-later in its rooms needs Hub-side crypto from the mautrix-go crypto helper. That is deferred to M3.

**System room.** At init the Hub creates a DM from `@switchboard:switchboard.internal` and sets it to notify on every message. It carries relink alerts, reminders, backup reports and update notices, so all operational alerts go through push you already have.

## Client architecture

The app has two layers. Below is a Rust crate, `switchboard-core`, that owns all Matrix logic. Above is a Flutter UI that only renders state and sends intents. The core exposes about 60 app-level functions through flutter\_rust\_bridge rather than binding the whole SDK. That keeps the binding surface small and testable, and the UI layer replaceable.

**Rust core (`core/`)**

- Built on `matrix-sdk` and `matrix-sdk-ui`. It uses `RoomListService` over simplified sliding sync for the chat list and `Timeline` for conversations.
- The room list is a stream of diffs. Each row is pre-computed in Rust: name, avatar, network (from the `m.bridge` state event), preview, unread and mention counts, tags, archive and reminder state, draft, typing.
- Timeline: back-pagination, plus an offline-first send queue that retries when the server is reachable again. Also edits, redactions, reactions, replies, threads, typing notices, public or private read receipts, and upload progress.
- Account data, tags and push rules; server-side search through `/search`; a typed client for the Hub API.
- Local cache in the SDK's SQLite store, encrypted with a 32-byte key held in Keychain (Apple), Keystore (Android) or libsecret (Linux).

**Flutter app (`app/`)**

- Dart 3, Riverpod for state, go\_router for navigation. The layout adapts by width: 3 panes at 900 px or more, 2 panes on tablets, 1 pane under 600 px.
- Packages: `flutter_inappwebview` (cookie logins on iOS, Android and macOS), `qr_flutter`, `media_kit` (audio and video on every platform, Linux included), `record` (voice notes), `super_clipboard` and `desktop_drop` (paste and drag in images), `window_manager` and `tray_manager` (desktop), `flutter_local_notifications`, `unifiedpush`, `local_auth` (optional app lock).
- Offline behaviour: the cached list and timelines show instantly. A banner reads "Can't reach Switchboard — messages will send when connected".
- Targets: 120 Hz scrolling on the iPhone 16 Pro, and a chat opening from cache in under 300 ms.

**Per platform**

| Platform | Install | Background and push | Specifics |
| --- | --- | --- | --- |
| iOS | An Xcode build on your own device. With a paid account: TestFlight | APNs through Sygnal. A Notification Service Extension fetches the message over the tailnet to show sender and text. Free team: no push, see Notifications | Share extension, Tailscale On Demand rule for the `switchboard` host |
| Android | Signed APK, updates through Obtainium | UnifiedPush through the ntfy app; no Google services needed | Direct-share targets, inline reply from notifications |
| macOS | `.app`, ad-hoc signed (Developer ID once paid) | Keeps a live sync connection; menu-bar item; launches at login | Keyboard-first, drag and drop |
| Linux | AppImage and `.deb`, arm64 and x86\_64 | Live sync; tray via StatusNotifierItem; freedesktop notifications; autostart entry | Wayland and X11. Cookie logins are best-effort here (see Account linking) |

Every device needs Tailscale running to reach the backend. The app detects "tailnet down" separately from "server down" and says which.

## Feature parity with Beeper

Every Beeper feature in the [inbox guide](https://help.beeper.com/inbox-tips-and-tricks-all-apps-guide) and the Beeper Plus tier has an equivalent below. Beeper Plus features come free here, because they run on your Hub. Where a network lacks a feature (edits on some, threads on most), the app reads the bridge's capability flags and hides the action.

| Area | Feature | Beeper | Switchboard implementation | Milestone |
| --- | --- | --- | --- | --- |
| Inbox | Unified inbox, newest first | Yes | Sliding-sync room list, network badge on each avatar | M1 |
| Inbox | Per-network and per-account views | Yes (spaces) | Sidebar entries built from `m.bridge` state and the bridges' personal filtering spaces | M1 |
| Inbox | Pinned chats, drag to reorder | Yes | `m.favourite` tag with `order`; avatar grid at the top of the list | M2 |
| Inbox | Archive; returns on new activity | Yes | `app.switchboard.inbox.done` with `at_ts`; the chat returns when a newer event arrives or it is marked unread | M2 |
| Inbox | Low Priority: muted except mentions and replies | Yes | `m.lowpriority` tag plus a muting room push rule. Mention rules still fire | M2 |
| Inbox | Mute | Yes | Room push rule with no actions | M2 |
| Inbox | Mark unread | Yes | `m.marked_unread` room account data | M2 |
| Inbox | Requests folder (Instagram, X) | Yes | Bridge's message-request flag, with accept and delete actions | M2 |
| Inbox | Labels | Yes | User tags `u.<label>`, each a sidebar entry | M2 |
| Inbox | Filters: Unread, Drafts, Unanswered, DMs, Groups | Yes | Computed in the core. Unanswered means the last message isn't from you | M2 |
| Inbox | Multi-select bulk actions | Desktop and iOS | All platforms | M2 |
| Inbox | "Show in All Inbox" per account: none, DMs, all | Yes | Per-login setting in account data | M2 |
| Inbox | Merge chats with one person across networks | Mobile | `app.switchboard.merged` account data: one row, with a network picker in the composer | M3 |
| Inbox | Note to Self | Yes | A room with only you in it, found through `app.switchboard.note_to_self` account data, plus a Notes view gathering it and each network's own self-chat (Signal Note to Self, WhatsApp message yourself, Telegram Saved Messages). Notepad avatar | Done (31 Oct) |
| Inbox | Remind me | Plus | Hub reminders | M2 |
| Inbox | Send later | Plus | Hub scheduled sends | M2 |
| Messages | Formatting, mentions, emoji | Yes | Markdown composer, limited to what the network supports | M1 |
| Messages | Replies, reactions, edits, unsend | Yes | Per network, from the bridge's `com.beeper.room_features` capabilities | M1 |
| Messages | Photos, video, files, voice notes, stickers | Yes | Synapse authenticated media; voice notes recorded in-app | M1 |
| Messages | GIF search | Yes | Tenor or Giphy API key stored in the Hub | M2 |
| Messages | Read receipts and typing | Yes | Ghost users' receipts shown as "Seen" avatars; typing both ways | M1 |
| Messages | Delivery status, failure and retry | Yes | `com.beeper.message_send_status` events drive ticks, the failed state and retry | M1 |
| Messages | Incognito reading | Plus | Sends `m.read.private` and suppresses typing, globally or per chat | M2 |
| Messages | Drafts synced across devices | Text only | `app.switchboard.draft` room account data, saved after 1 s idle | M2 |
| Messages | Link previews | Yes | Synapse URL previews | M1 |
| Messages | Threads and topics | Where supported | Slack threads, Telegram topics | M2 |
| Messages | Forward | Yes | Re-sends content to another chat | M2 |
| Messages | Voice-note transcription | Plus (AI) | Optional whisper.cpp container called by the Hub | M3 |
| Messages | Block users | Yes | Bridge block support, added October 2026 | M3 |
| Search | Search chats, contacts, messages | Yes | Postgres full-text through Synapse `/search`, plus a local filter on names | M2 |
| Contacts | New chat or group on any network | Yes | Hub contact search, then `create_dm` or `create_group` | M2 |
| Accounts | Several accounts per network | Plus | Several logins per bridge; Accounts groups them by network with Add another; a chat's header names its account when a network has several | Done (31 Oct) |
| Accounts | Link, relink, unlink in the app | Yes | Generic login-step renderer (see Account linking) | M1 QR and code, M2 cookies |
| Accounts | Connection health | Yes | Hub `/bridges` and its event stream | M1 |
| App | Keyboard shortcuts and command bar | Desktop | See UI design | M1 |
| App | Notifications with inline reply | Yes | See Notifications | M2 |
| App | Light and dark themes; Minimal or Pro list density | Yes | Theme tokens; density toggle | M2 |
| App | Desktop API for automation | Yes | Optional MCP endpoint on the Hub, tailnet-only | M3 |

## UI and interaction design

On the left is a narrow sidebar of views and networks. Next is the chat list, with pinned chats as an avatar grid on top. The conversation fills the rest, and a right panel opens for chat info. Network colour appears only in the small badge on each avatar. Everything else is neutral surfaces with one accent colour.

![Desktop wireframe · sidebar, chat list, conversation](img/desktop-wireframe.png)

The wireframe shows the row states the list must draw: unread count, red draft prefix, muted, reminder chip, mention. The conversation shows a reaction, a quoted reply with "Seen", and a failed send with retry. Status dots in the sidebar flag a reconnecting Telegram and an Instagram login that needs relinking.

**Desktop, 900 px and wider**

- *Sidebar*, collapsible from 220 px to 64 px. Views: Inbox, Low Priority, Archive, Requests, Reminders, Send later. Then one entry per network, each with a status dot (green connected, amber reconnecting, red needs relink). Then labels, with Settings at the bottom.
- *Chat list*, 320 px. A search field (⌘K) and filter chips: Unread, Drafts, Unanswered, DMs, Groups. A pinned grid, then rows. Each row shows the avatar with its network badge, name, preview ("Sender: text"), time, and unread or @ count. It also shows a muted icon, a red "Draft:" prefix and a reminder chip when they apply. Hovering shows archive and pin buttons; right-click opens the full menu.
- *Conversation*. The header shows avatar, name, network and account, member count, search in chat, and the info toggle. Bubbles: yours on the right in the accent tint, consecutive messages grouped, sender names in groups, day separators. Each message can show a reaction row, a quoted reply, "Seen" avatars, a delivery tick, or a failed icon with retry.
- *Composer*. Attach, emoji, GIF and voice-record buttons. Right-click or long-press Send for Send later. A reply or edit banner sits above it. Actions the network can't do are hidden.
- *Right panel*. Participants, shared media, notification level, labels, archive and low-priority toggles, and bridge and account details.

**Mobile, under 600 px**

- Chat list full screen. The title menu holds Select chats, Merge chats and Settings. Pinned grid on top. The bottom bar has the filter button on the left, search, and the view switcher.
- Swipes: right toggles read and unread, left archives. Both are configurable. Long-press opens Pin, Archive, Low Priority, Mute, Mark unread, Remind me and Label.
- In a chat: swipe a message right to reply. Long-press shows the reaction bar plus Reply, Edit, Copy, Forward, Unsend and Info.
- Settings: Accounts, Notifications, Preferences (swipes, density, theme, incognito), Storage, and About (app and backend versions).

**Accounts screen** (all platforms). One card per login shows the network icon, remote name and number or handle, a state badge, and the last sync time. Actions: Reconnect, Show in inbox (none, DMs, all), Restart bridge, Log out. "Add account" lists every enabled network.

**Keyboard shortcuts.** Defaults below, all rebindable. On Linux, Ctrl replaces ⌘.

| Action | Shortcut |
| --- | --- |
| Jump to chat, command bar | ⌘K |
| Search all messages | ⌘⇧F |
| Search in chat | ⌘F |
| New chat | ⌘N |
| Next or previous chat | ⌥↓ / ⌥↑ |
| Next unread chat | ⌥⇧↓ |
| Jump to pinned chat 1–9 | ⌘1…⌘9 |
| Archive | ⌘E |
| Mark unread | ⌘⇧U |
| Pin or unpin | ⌘⇧P |
| Remind me | ⌘⇧R |
| Send later | ⌘⇧↩ |
| Edit last message | ↑ in an empty composer |
| Toggle chat info | ⌘I |
| Settings | ⌘, |
| Cancel reply or close panel | Esc |

## Account linking UX

One generic renderer links every bridgev2 network. It walks the provisioning API's login steps and draws each step type natively, so a new bridge needs no new app code. Logins live on the server: link once from whichever device is easiest, and every device has the account.

**Flow**

1. Add account, then pick a network. The app fetches `login/flows`. If there are several (for example "QR code" and "Phone number"), it shows them with the bridge's own descriptions.
2. `login/start/{flow}` returns the first step. The renderer loops until `complete` or an error. Cancel is always available and calls `login/cancel`.
3. On `complete`, the new account card appears. The event stream shows it go from connecting to connected, and chats appear as the bridge creates them, with a backfill progress bar.
4. Follow-ups such as Messenger's backup PIN arrive as further `user_input` steps, marked skippable.

| Step type | What the app shows | Platform notes |
| --- | --- | --- |
| `display_and_wait`, `qr` | Full-screen QR, from `image_url` when given or rendered from `data`, with the bridge's instructions. It redraws when the bridge rotates the code, then long-polls for the next step | A phone can't scan its own screen. Offer "Use phone number instead" where the network has one, or "Continue on another device" |
| `display_and_wait`, `emoji` or `code` | Large emoji or code to match on your phone | Google account pairing uses this |
| `display_and_wait`, `nothing` | Spinner and instructions | — |
| `user_input` | A native form built from the fields: phone number with country picker, 2FA code with one-time-code autofill, secure password, token, email, URL, domain, username, select. It checks `pattern` and length before submitting | — |
| `cookies` | An in-app webview at `url` with the given `user_agent`. When the URL matches `wait_for_url_pattern`, it extracts each field: cookies from the native store (HttpOnly included), local storage by script, request headers and bodies by fetch and XHR hooks injected at document start, then `extract_js`. `hidden` runs it off-screen | iOS `WKHTTPCookieStore`, Android `CookieManager`, macOS `WKWebView`. Linux is best-effort on WebKitGTK; otherwise "Finish on another device" |
| `client_http` | Runs the HTTP request from the device and returns status, final URL, headers and body | Lets the bridge use your device's network identity |
| `webauthn` | Platform passkey prompt: AuthenticationServices on Apple, Credential Manager on Android | Linux hands off |
| `complete` | Success screen, then the account card | — |

**Continue on another device.** The login process belongs to your user on the bridge, not to one device. "Continue on another device" sends `{bridge, loginProcessID, stepID}` through the Hub's event stream. Every other signed-in device then shows a "Continue WhatsApp login here" prompt and resumes at the same step. This solves Signal's QR-only linking when you're on your phone: the QR shows on a desktop.

**Per network, the easiest path**

- *WhatsApp*: on a desktop, scan the QR. On the iPhone alone, use the phone-number pairing code: enter your number, then type the 8-character code into WhatsApp under Linked devices, Link with phone number.
- *Signal*: QR only. Use the Mac or Linux app, or hand off from the phone.
- *Telegram*: phone number, then the code Telegram sends to your app, then your 2FA password.
- *Messenger, Instagram, X, LinkedIn, Slack*: webview login, with the site's own 2FA inside it. Do it on the phone or the Mac, not Linux.
- *Discord*: the bridgev2 rewrite offers email or phone and password with 2FA, so it links in the app like the rest; its browser flow uses the cookies step.
- *Google Chat* (legacy bridge): the app opens the bridge bot's chat, sends `login`, and shows the bot's replies (QR images, prompts) as a guided conversation with quick-reply buttons.
- *Matrix*: homeserver, username and password, then the account's recovery key so encrypted rooms and their history can be read.

**Relink and log out.** An account in a red state shows Reconnect, which runs the same flow. bridgev2 matches the remote account to the existing login, so chats are kept. Log out asks for confirmation and offers "Also remove chats".

## Notifications and push

Synapse evaluates push rules and calls one pusher per mobile device. Message text never rides in a push payload: pushers are `event_id_only`, and the device fetches the message over the tailnet. Desktop apps need no push, because they keep a live sync connection open.

| Device | Path | Extra cost |
| --- | --- | --- |
| iPhone, paid Apple account | Synapse, then Sygnal, then APNs. The Notification Service Extension fetches the event over the tailnet and shows "Sender · WhatsApp: text". If the fetch fails it shows "New message" | $99/year |
| iPhone, free personal team | No APNs entitlement. The Hub acts as push gateway: it fetches the event, formats it and publishes to the stack's ntfy server. ntfy forwards only a content-free poll request through ntfy.sh to the ntfy iOS app, which fetches the text from your server. Tapping opens `switchboard://room/<id>` | None, but alerts come from the ntfy app, and builds expire every 7 days |
| Android | Synapse, then ntfy's Matrix push gateway, then the ntfy app as UnifiedPush distributor, then Switchboard. The app fetches the event and shows a conversation-style notification | None |
| macOS, Linux | No pusher. The menu-bar or tray app keeps sync open and posts local notifications. A fully quit app gets nothing, as with Beeper Desktop | None |

**Rules**

- Per-chat levels are All, Mentions and replies, and Off. Low Priority means mentions and replies, plus removal from the inbox. Defaults are All for DMs and groups, with an option to make groups mentions-only.
- Keyword rules for your name. The System room always notifies.
- Notification actions: inline Reply and Mark read on iOS, Android and macOS. Replies go through the core's send queue, so they survive a flaky connection.
- When a room's read receipt syncs, the app clears that room's delivered notifications. On iOS that happens the next time the app or its extension runs.
- OS Focus and Do Not Disturb are respected; the app adds no quiet-hours system of its own.

## Security, privacy and networking

The most valuable asset is the Postgres data. It holds the session cookies and tokens for every linked network, so anyone with a copy can act as you everywhere. The design keeps it off the internet, encrypted at rest, and backed up only in encrypted form.

**Network**

- The only way in is the tailnet. A tailnet ACL grants port 443 on `tag:switchboard` to your own devices and nothing else. No Funnel, no router port forwards.
- Turn off key expiry for the `switchboard` node and the host. Tailscale node keys expire after 180 days by default, and an expired key means no messages until someone renews it.
- The sidecar joins with a tagged, pre-authorised auth key. Its state lives in a named volume, so it keeps its identity across restarts.
- TLS comes from Tailscale Serve's `*.ts.net` certificate, renewed automatically. Caddy refuses `/_synapse/admin`, `/_matrix/federation` and `/_matrix/key`.
- No host ports are published except Synapse on `127.0.0.1:8008`.

**Secrets and data at rest**

- `sb init` generates every secret from 32 random bytes into `secrets/` with mode 600. The directory is git-ignored and only leaves the host inside encrypted restic snapshots, whose password is in the Keychain.
- On a Mac, FileVault covers the Docker VM disk, which lives in your home folder, and `sb doctor` checks `fdesetup status`. On Linux, use full-disk encryption.
- The socket proxy limits the Hub to listing, logs and restart. No other container sees the Docker socket.

**Devices**

- Access tokens live in Keychain, Keystore or libsecret. The local cache is encrypted. App lock with Face ID or fingerprint is optional.
- Settings, Devices lists every signed-in device and can sign one out. `sb devices revoke` does the same from the host.
- Synapse has no built-in second factor without a separate auth service. Tailnet membership serves as the second factor, on top of a long password.

**Privacy**

- No telemetry. Push payloads carry no content. On the free-iOS route, ntfy.sh sees only opaque poll IDs.
- GIF search goes through the Hub, so Tenor or Giphy see the server's IP, not your phone's.

**Account-ban risk.** WhatsApp, Signal and Telegram links use each network's official multi-device mechanism. The cookie-based networks (Meta, X, LinkedIn) can flag unusual sessions, such as a login from one place while the bridge's traffic comes from the server's IP somewhere else. Link those accounts from the server's network where you can, and keep each bridge's user agent fixed.

## Matrix conventions

All inbox state lives in Matrix itself, as tags, account data and push rules. Every device therefore agrees without the Hub, and a backup of Synapse captures it. The app reads Beeper-namespaced events exactly as the bridges send them. Its own keys use the prefix `app.switchboard.`; fix the final prefix before M1, because changing it later needs a migration.

| Key | Kind | Written by | Meaning | Origin |
| --- | --- | --- | --- | --- |
| `m.bridge` | Room state | Bridge | Network, icon, and which account the chat belongs to | MSC2346 |
| `com.beeper.room_features` | Room state | Bridge | Capabilities: formatting, edits, reactions, unsend, file size limits | Beeper extension |
| `com.beeper.message_send_status` | Room event | Bridge | Delivered, failed or retriable status for a message you sent | Beeper extension |
| Message-request flag | Room state | Bridge | Files the chat under Requests. Confirm the exact key in mautrix-go before M2 | Beeper extension |
| Personal filtering spaces | `m.space` rooms | Bridge | One space per account, used for sidebar views | mautrix |
| `m.receipt` from ghost users | Ephemeral | Bridge | "Seen" on the remote network | Spec |
| `m.read.private` | Receipt | App | Incognito read: stays on your server, not sent to the network | Spec |
| `m.marked_unread` | Room account data | App | Mark unread | Spec v1.12 |
| `m.favourite` tag with `order` | Room tag | App | Pinned, in drag order | Spec |
| `m.lowpriority` tag | Room tag | App | Low Priority | Spec |
| `u.<label>` tags | Room tag | App | Labels | Spec |
| Room push rule | Push rules | App | Mute, or mentions and replies only | Spec |
| `app.switchboard.inbox.done` `{at_ts}` | Room account data | App | Archived until a message from someone else is newer than `at_ts`, or the chat is marked unread. Your own messages don't unarchive it | Switchboard |
| `app.switchboard.reminder` `{remind_at, fired_ts, note}` | Room account data | Hub on firing; app for display | Reminder chip and Reminders view. The Hub database is the source of truth | Switchboard |
| `app.switchboard.draft` `{body, formatted_body, reply_to, updated_ts}` | Room account data | App | Synced text drafts | Switchboard |
| `app.switchboard.merged` `{groups}` | Global account data | App | Chats merged into one row | Switchboard |
| `app.switchboard.note_to_self` `{room_id}` | Global account data | App | The Note to Self room, so every device opens the same one | Switchboard |
| `app.switchboard.account_prefs` | Global account data | App | Show in All Inbox (none, DMs, all) per login | Switchboard |
| `app.switchboard.incognito` | Global account data, room override | App | Incognito on or off | Switchboard |

## Testing

Testing rests on one piece of tooling, a fake bridge. It exercises every login step type and message feature without real accounts. Real networks are then checked nightly through self-chats, so no contact ever receives a test message.

- **`testbridge`.** A small bridgev2 network connector in the repo. It offers one login flow per step type: QR, emoji, `user_input` with every field type, `cookies` against a local test page, `client_http`, and a `webauthn` stub. It echoes messages back with reactions, edits, receipts and send statuses, so the renderer, timeline and delivery ticks are tested end to end.
- **Backend.** Golden-file tests for `sb` config rendering against each pinned image's example config. An integration profile brings up Postgres, Synapse, the Hub and `testbridge`, then runs the Hub API suite.
- **Rust core.** Unit tests, plus integration tests against the integration profile: sync, pagination, send queue offline and online, account data round-trips.
- **Flutter.** Widget and golden-screenshot tests for every chat-row state, bubble state and login step. Integration tests run on the iOS Simulator, the Android emulator, macOS, and Linux under Xvfb in Docker.
- **Live round-trip, nightly after the backup.** `sb doctor --roundtrip` sends a timestamped message to each network's self-chat: WhatsApp "Message yourself", Signal "Note to Self", Telegram "Saved Messages", a Slack DM to yourself. It confirms the echo and a delivered status. Networks without a self-chat get a bridge-state check only. Failures post to the System room.
- **Restore drill.** Quarterly `sb restore --scratch`, as described under Automation.
- **Dogfood gates.** Each milestone ends with a week of daily use on the target platforms before the next starts.

## Delivery plan

Beeper comes off every device after about 10 weeks of work. The backend comes first and is proven with an off-the-shelf Matrix client, so the app is never built against a moving target.

![Delivery plan · 4 phases, 3 gates](img/delivery-plan.svg)

Each phase ends at a gate held for a week of daily use (see Testing). Accounts are linked from inside the app, as in Beeper, so M0 ends when `sb test` passes and linking arrives with M1. M1 builds the iOS app; M2 adds the Linux desktop app, then macOS and Android. M3 items are independent and can be taken in any order once Beeper is gone.

## Risks and open questions

The biggest risk is the host as a single point of failure while nobody is near it. Close behind is the work of binding matrix-rust-sdk to Flutter. Both have a fallback.

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| After a power cut or forced restart, FileVault needs someone to unlock a Mac host; everything stops until then | Medium | All messaging down | UPS; auto-install of OS updates off; `fdesetup authrestart` for planned restarts. Or run the stack on a Linux host that boots unattended: the Tailscale sidecar keeps the URL |
| The flutter\_rust\_bridge layer over matrix-rust-sdk takes longer than planned | Medium | M1 slips | Keep the facade to about 60 functions. If it stalls past 2 weeks, switch the core to famedly's Dart SDK behind the same interface |
| A network changes protocol and its bridge breaks, as Instagram did in July 2026 | High, yearly | One network down for days to weeks | Monthly updates; relink alerts; the native app as fallback |
| Free iOS builds expire every 7 days and get no push | Certain without paying | Missed messages; weekly reinstall | Apple Developer Program, or the ntfy route plus weekly reinstall reminders |
| WhatsApp drops linked devices after about 14 days of phone inactivity | Low | WhatsApp unlinks | Keep WhatsApp opened on the phone; the relink alert catches it |
| Cookie-based networks flag the bridge session | Low to medium | Account checkpoint or ban | Link from the server's network, fixed user agents, no bulk actions |
| Discord bridgev2 rewrite lands mid-project | Likely | Migration work | Treat it as a planned swap: new bridge, relink, retire the legacy rooms |
| Synapse database and media grow without limit | Certain, slowly | Disk fills | `sb status` shows growth; state compression and media retention jobs from M3 |

**Open questions**

- [ ] Pay for the Apple Developer Program?
- [ ] Final network list, and whether iMessage is worth the host bridge.
- [ ] Backup destination and offsite copy.
- [ ] Do you need a web client later? It is out of v1 scope; Flutter web would make it cheap.
- [ ] Which always-on host suits the stack long term: a Mac or a Linux box?

## Appendix: repo layout and Compose sketch

One monorepo. Generated files and secrets are git-ignored, so the repo can be pushed anywhere without leaking anything.

```
switchboard/
├── sb/                     Go module: cmd/sb (CLI), cmd/hub (Hub)
│   └── internal/           catalogue, render, provisioning proxy, scheduler, testbridge
├── deploy/
│   ├── compose.yaml        core services (below)
│   ├── compose.bridges.yml generated from bridges.yaml
│   ├── bridges.yaml        bridge catalogue
│   ├── versions.env        pinned image tags
│   ├── overlays/           shared.yaml + one per bridge
│   ├── config/             rendered configs (ignored)
│   ├── appservices/        rendered registrations (ignored)
│   ├── secrets/            mode 600 (ignored)
│   └── launchd/            backup and iMessage agents
├── core/                   Rust: switchboard-core over matrix-sdk
├── app/                    Flutter: ios, android, macos, linux
└── docs/
```

`deploy/compose.yaml`, abridged:

```yaml
name: switchboard
services:
  tailscale:
    image: tailscale/tailscale:stable
    hostname: switchboard
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_EXTRA_ARGS: --advertise-tags=tag:switchboard
      TS_USERSPACE: "true"
      TS_STATE_DIR: /var/lib/tailscale
      TS_SERVE_CONFIG: /config/serve.json   # 443 -> caddy:80, 8443 -> ntfy:80
    volumes: [ts-state:/var/lib/tailscale, ./config/tailscale:/config:ro]
    restart: unless-stopped

  caddy:
    image: caddy:2
    volumes: [./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro]
    restart: unless-stopped

  postgres:
    image: postgres:18-alpine
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_root
    secrets: [pg_root]
    volumes: [pg-data:/var/lib/postgresql]
    healthcheck: { test: [CMD, pg_isready, -U, postgres], interval: 10s }
    restart: unless-stopped

  synapse:
    image: matrixdotorg/synapse:${SYNAPSE_TAG}
    environment: { SYNAPSE_CONFIG_PATH: /data/config/homeserver.yaml }
    volumes:
      - ./config/synapse:/data/config:ro
      - ./appservices:/data/appservices:ro
      - synapse-media:/data/media
    ports: ["127.0.0.1:8008:8008"]
    depends_on: { postgres: { condition: service_healthy } }
    healthcheck: { test: [CMD, curl, -fsS, http://localhost:8008/health] }
    restart: unless-stopped

  hub:
    build: ../sb
    command: [hub]
    environment: { DOCKER_HOST: tcp://socket-proxy:2375 }
    volumes: [./config/hub:/config:ro]
    depends_on: { synapse: { condition: service_healthy } }
    restart: unless-stopped

  socket-proxy:
    image: tecnativa/docker-socket-proxy
    environment: { CONTAINERS: 1, POST: 1, ALLOW_RESTARTS: 1 }
    volumes: [/var/run/docker.sock:/var/run/docker.sock:ro]
    restart: unless-stopped

  ntfy:
    image: binwiederhier/ntfy
    command: serve
    volumes: [./config/ntfy:/etc/ntfy:ro, ntfy-cache:/var/cache/ntfy]
    restart: unless-stopped

volumes: { ts-state: {}, pg-data: {}, synapse-media: {}, ntfy-cache: {} }
secrets: { pg_root: { file: ./secrets/pg_root } }
```

One generated entry in `compose.bridges.yml`:

```yaml
  mautrix-whatsapp:
    image: dock.mau.dev/mautrix/whatsapp:${WHATSAPP_TAG}
    volumes: [./config/bridges/whatsapp:/data]
    depends_on: { synapse: { condition: service_healthy } }
    healthcheck: { test: [CMD, wget, -qO-, http://localhost:29318/_matrix/mau/ready] }
    restart: unless-stopped
```

`config/caddy/Caddyfile`:

```
:80 {
  @blocked path /_synapse/admin* /_matrix/federation* /_matrix/key*
  respond @blocked 404
  handle /.well-known/matrix/client {
    header Content-Type application/json
    respond `{"m.homeserver":{"base_url":"https://switchboard.<tailnet>.ts.net"}}`
  }
  handle /_switchboard/* {
    reverse_proxy hub:8090
  }
  handle {
    reverse_proxy synapse:8008
  }
}
```

## Sources

- [mautrix bridges documentation](https://docs.mau.fi/bridges/)
- [mautrix blog index, 2024–2026 release posts](https://mau.fi/blog/)
- [April 2026 releases: Telegram Go release](https://mau.fi/blog/2026-04-mautrix-release/)
- [July 2026 releases: new Instagram bridge](https://mau.fi/blog/2026-07-mautrix-release/)
- [October 2026 releases: encrypted Messenger backfill, blocking](https://mau.fi/blog/2026-10-mautrix-release/)
- [Introducing mautrix-manager](https://mau.fi/blog/introducing-mautrix-manager/)
- [bridgev2 provisioning API spec](https://github.com/mautrix/go/blob/main/bridgev2/matrix/provisioning.yaml)
- [End-to-bridge encryption](https://docs.mau.fi/bridges/general/end-to-bridge-encryption.html)
- [Double puppeting](https://docs.mau.fi/bridges/general/double-puppeting.html)
- [Beeper inbox tips and tricks](https://help.beeper.com/inbox-tips-and-tricks-all-apps-guide)
- [matrix-docker-ansible-deploy: RustPush iMessage bridge](https://git.cqre.net/cqrenet/matrix-docker-ansible-deploy/commit/11cd178cb2232bbd14eff6a2aca4b53a4e5a3941)
