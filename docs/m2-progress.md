# M2 progress: Linux app

M2 adds the Linux desktop app, then macOS and Android. See the delivery plan
in [spec.md](spec.md). This file is updated as work lands.

## Layout

| Path | What |
| --- | --- |
| `app/linux/` | GTK runner. App ID `com.richarddraycott.switchboard`; single instance (a second launch raises the window); `--minimized` starts in the tray |
| `app/lib/src/desktop.dart` | Tray icon and menu, close to tray, desktop notifications, start at login |
| `app/lib/src/ui/home_shell.dart` | Wide layout: sidebar, chat list and conversation; jump bar; inbox shortcuts |
| `app/lib/src/ui/layout.dart` | Pane breakpoints, `isDesktop`, Ctrl or ⌘ shortcuts |
| `app/lib/src/state/notify.dart` | Which chats notify, and what the notification says |
| `app/assets/icon/` | App and tray icons: SVG sources and rendered PNGs |
| `app/tool/linux-shot.sh` | Open a route in the debug build under Xvfb and screenshot it |
| `app/linux/runner/web_login.cc` | WebKitGTK sign-in window for the bridges' `cookies` step, on the `switchboard/web_login` channel |
| `app/lib/src/ui/login_window.dart` | Dart side of that channel. `web_login.dart` drives it on Linux the way it drives InAppWebView elsewhere |
| `app/tool/linux-web-login-test.sh` | Runs `integration_test/web_login_test.dart` (the real sign-in window against a local page) under Xvfb on a private D-Bus bus |
| `packaging/arch/PKGBUILD` | Arch package built from the repo's committed HEAD: `yay -Bi packaging/arch` |

## Done

- [x] Toolchain: Flutter 3.47.9, rustup `stable` at 1.99.1. cargokit builds the core with `rustup run stable`, so `core/rust-toolchain.toml` doesn't apply to app builds
- [x] Linux runner; the core builds through cargokit; the device is named "Switchboard Linux"; session and store key in libsecret
- [x] Layout by width: sidebar, 320 px list and conversation from 900 px; list and conversation from 600 px; the phone layout below that. Phones stay one pane when turned sideways. Sidebar views have unread counts and status dots from the Hub (green connected, amber reconnecting, red needs relinking or bridge down), and collapse to icons
- [x] Shortcuts (Ctrl on Linux, ⌘ on macOS): Ctrl+K jump to chat, Alt+↑/↓ previous or next chat, Alt+Shift+↓ next unread, Ctrl+1 to 9 pinned chats, Ctrl+, Settings. In the composer: Enter sends, Shift+Enter adds a line, ↑ in an empty composer edits your last message, Esc cancels a reply or edit. The rest of the spec's list waits for its M2 features
- [x] Messages on desktop: right-click opens the actions as a menu with the reactions on top; Reply and More on hover; bubbles sized to the conversation pane
- [x] Files on desktop: open in the default app, and Save as (share_plus can't share files on Linux); drag files onto a chat, or paste files or an image with Ctrl+V, then confirm. Camera shows only where image_picker has one
- [x] Tray: icon with an unread dot, Show and Quit. Closing the window hides it so sync keeps running. Settings has Start at login, which writes an XDG autostart entry
- [x] Notifications while the app runs: a chat whose unread count rises (Synapse's push-rule count, so muted chats stay quiet) raises "Sender in Group · Network", unless it's the chat on screen in a focused window. Clicking opens it; reading it anywhere takes it down; more than 3 chats at once get one summary
- [x] Core fix for every platform: the room list's sliding sync doesn't request `m.bridge` or `com.beeper.room_features`, so every portal had no network (empty per-network views, no badges) and no features (every action offered). The core now fetches the room's state from the server when the store has none, at most 4 rooms at a time, saves the network in the store's custom values, and resends the room to the list
- [x] Arch package: release build, plugins' RUNPATH set to `$ORIGIN`, desktop entry and icons. The packaged binary starts and draws under Xvfb on an isolated D-Bus bus
- [x] Tests: shell layout at three widths and the shortcuts; composer keys, right-click menu, hover, paste; notification rules; status dots; list stepping and jump matching. Rust tests for reading full room state and tracking the list's room IDs

## Networks and fixes, 31 Oct (branch `networks`)

- [x] Sign-in labels sat half outside their boxes (the theme's borderless outline border floats labels onto the edge); an underline border keeps them inside, on sign-in and in login forms
- [x] Pictures: Signal now uses contact photos and last-known profiles (`deploy/overlays/signal.yaml`); a DM with no picture of its own shows the other person's, from the room summary. Most Signal contacts had none on the server, so the app had nothing to show
- [x] Several accounts per network: the bridges already allow it; Accounts groups logins by network with Add another, and a chat's header names its account when a network has several
- [x] Instagram, Slack and Discord bridges enabled. Discord moved to the bridgev2 rewrite (`megadiscord`, pinned by digest)
- [x] In-app web logins (the bridgev2 `cookies` step) with flutter_inappwebview: cookies including HttpOnly, local storage, request headers and bodies from injected fetch/XHR hooks, the bridge's extraction script; clean cookie jar per login. Linux opens the page in a WebKitGTK window instead (see "Web logins on Linux")
- [x] Note to Self and a Notes view (Switchboard note plus each network's self-chat), notepad avatar
- [x] Matrix: `bridges/matrix` is a bridgev2 connector (`sb-matrix`) for outside Matrix accounts, with end-to-end encryption (goolm), recovery-key verification and key-backup restore, media both ways, replies, threads, edits, reactions, redactions, receipts, typing and forward backfill. `sb` builds bridges with a `build:` entry in `bridges.yaml`
- [x] Matrix bridge checked end to end on 31 Oct against a throwaway second Synapse on the Compose network (two users; removed afterwards, test chats purged): link through the Hub with password and skipped recovery key; outside DM appears named after the contact; formatted text, image, edit, reaction and its removal, and deletion come in; reply, reaction and its removal, and edit go out, with no echo duplicates; a message from the account's other app shows as the owner; an encrypted DM decrypts both ways, live and in backfill. Not yet tried with a real recovery key or key backup
- [ ] Telegram: needs an API ID and hash from my.telegram.org
- [ ] Real logins for Instagram, Slack, Discord and Matrix from a phone

## More fixes, 31 Oct evening (branch `networks`)

- [x] Favourites: Favourite or Remove from Favourites by press-and-hold or right-click on a chat (or the grid), and a star in the chat header. Favourites stay as the grid on top of the inbox, in their `m.favourite` order; a Favourites view (switcher and sidebar) lists them with drag handles to reorder, saving evenly spread orders
- [x] Opening a chat from a notification showed only the new message. Cause: the open chat wasn't subscribed in sliding sync, so its events came through the room list (one per room), and a "limited" update shrank the cached timeline to the newest message; the app paged back only once, on the first update. The core now subscribes the open chat (`reset_and_add_room_subscriptions`, as Element X does), and the app pages back until 20 messages show, after resets too, retrying with backoff when offline
- [x] Instagram reels arrive as their still with `com.beeper.unresolved_media`. They show a play button; tapping calls the bridge's `POST /v3/resolve_media/{event}` through the Hub (with the chat's login), the bridge edits the message into the video, and it opens by itself. Checked against the live bridge (MP4 in under a second). Edits flagged `com.beeper.dont_render_edited` no longer show "edited"
- [x] Reddit links: the preview card shows a play button; tapping loads the post in a hidden web view (Reddit serves a browser check, and its JSON API refuses anonymous requests), reads the `shreddit-player` stream (HLS) and plays it in the app's player; posts without video open in the browser as before. Linux uses the WebKitGTK window in hidden mode. Checked on the iOS Simulator with a real share link (`/debug/video?url=…`, debug builds only)
- [x] Linux: the Reddit resolver works in the hidden WebKitGTK window (checked on an Arch machine, ~1.8 s). Arch's FFmpeg (system libmpv) stops Reddit's CMAF HLS after one segment, so Linux plays the DASH manifest of the same video instead; hidden windows no longer allow media to start without a gesture (WebKitGTK's default allowed it)
- [x] Videos play in place: tapping a video (or a reel, once fetched, or a Reddit card) plays it inside the bubble with media_kit's controls; their full-screen button fills the screen with the whole video, upright for tall videos and sideways for wide ones (media_kit's default forced landscape, which shrank or cropped reels)
- [x] Review fixes: Inbox title has a chevron; menus are rounded like the sheets; one entry per network (rooms carry the bridge type, `instagramgo`, which the app now uses as the protocol ID and badges understand); chats the server deleted are dropped from the device's store and hidden (`forget_stale_rooms`)
- [ ] Linux: recheck Reddit playback with DASH and the gesture rule, and the in-place player
- [x] View switcher lists only networks with a linked account (bridges without logins are left out; before the Hub answers, the chats' networks stand in)
- [x] Inbox tools: Archive (room account data `app.switchboard.inbox.done` `{at_ts}`; out of every view but the new Archive view until someone else writes or it's marked unread; the core resends the room when that account data changes, since it doesn't touch the room's info), swipe left to archive (Undo) and right to toggle read or unread on phones, press-and-hold or right-click menu with Favourite, Mark read or unread, Archive and Select, select mode with Select all, Read, Unread and Archive, and Mark all as read in the ⋯ menu (one read receipt per chat for its newest event, no timelines). Desktop: Ctrl+E archive, Ctrl+Shift+U mark unread, Esc leaves select mode. Opening a chat clears its unread mark

- [x] One video or voice note plays at a time: starting one (from its own controls too) pauses the one playing (`state/playback.dart`)
- [x] iOS badge and Notification Center follow reads: the app sets the badge to the number of unread chats and removes delivered notifications for read chats (also read elsewhere) once sync is running; pushes alone only updated the badge when a message arrived. Linux already took notifications down on read

- [x] Badge still counted chats nobody can open: the bridges' account spaces and a chat with no messages (its notification was the invite). Reading now falls back to the server's newest event when a chat has no message to mark (also when opening it); the badge counts the inbox's unread chats; and the app marks bot chats and account spaces read once a session on every platform, so Synapse's count in each push is right too
- [x] Videos in bubbles have their own tap-only controls (play or pause, time left, progress, full screen): media_kit's register drag handlers even with gestures off, which stopped the chat scrolling (and swipe to reply) from a drag on the video. Full screen keeps media_kit's controls
- [x] Reddit lookups start when a card appears, one at a time, cached per link, with a 25 s limit (the iOS Simulator took 10 to 15 s cold)

## Search and media (7 Nov 2026, branch `wikoion/search-media`)

Search, a page of each chat's shared media, and saving photos and videos.
Search reads an index on the device, kept for a period the user picks and
showing the space it takes, with the server's search as a fallback.

- **Index** (`core/src/index.rs`): SQLite with FTS5 (`unicode61`, accents
  folded) at `<data dir>/search.sqlite3`, through the same `rusqlite` 0.40 and
  bundled SQLite that matrix-sdk-sqlite links. It holds messages, captions
  and file names; media details (mxc, thumbnail, size, dimensions); and the
  links found in text. Plain SQLite: unlike the SDK's store it isn't encrypted
  with the Keychain passphrase, so it relies on the platform's at-rest
  encryption (iOS Data Protection; the disk on Linux). Signing in again starts
  a new one; signing out empties it.
- **Indexer**: one task, started with sync. Each chat is caught up from its
  newest event (`/messages` backwards, filtered to messages, redactions and
  encrypted events, 200 a page) to the newest event already indexed, then
  filled back a page at a time to the start of the period, round-robin, so
  every chat's recent messages are searchable first. Every sync that brings a
  chat events queues it again. Paging back, an edit arrives before the
  message it edits, so edits seen first wait in `pending_edits`; a newer edit
  wins and only the sender's count. Unsends delete. Chats left are forgotten.
  Offline, it retries with backoff, sooner when a sync arrives. The journal
  is checkpointed when it goes idle, so the size shown is real.
- **Period**: Settings → Search: 1 month, 3, 6, 1 year (default) or
  everything, with the space used and progress. A shorter period prunes at
  once; a longer one starts every chat again from its newest event, since
  pruning leaves gaps behind the saved page tokens. Messages that age out
  are pruned at each start.
- **Search** (`search_screen.dart`): the bottom bar's search field on a phone;
  the list's search button, Ctrl+Shift+F, or Ctrl+F in a chat on desktop
  (a panel over the app). Chats by name, then messages, newest first, each
  word matched as a word prefix, matches in bold. A date filter (today, past
  week, month, year, or a range). In one chat from the chat's ⋯ menu.
  "Search older messages on the server" asks Synapse's `/search` (Postgres)
  for what the index doesn't hold, leaving out what it does.
- **Open at a message**: a result opens the chat on an event-focused timeline
  (`subscribe_timeline_at`, 30 events of context, paging both ways), the
  message lit up. Jump to latest, sending, or paging down to the newest
  switches to the live timeline. Reactions, edits and unsends find the event
  in whichever timeline holds it.
- **Media page** (`chat_media_screen.dart`, `/room/:id/media`): tap the chat's
  header, or ⋯ → Media, files and links. Media (a grid by month), Files and
  Links tabs. Pages come from the index, then from the server's history
  (`/messages` with `contains_url`) where the index ends, so it shows a chat's
  whole history; links come from the index only. Photos and videos open in a
  swipeable viewer with Save, Share (phone) and Show in chat.
- **Saving**: Save to Photos on iOS (`gal`, add-only access,
  `NSPhotoLibraryAddUsageDescription`), Save to Downloads on Linux, from the
  viewers, the media page and a message's menu. Files: open, or Save as.
- **Tests**: `cargo test --lib index` (parsing, edits either way round,
  unsends, prefix search, media paging, pruning); live
  `cargo test --lib -- --ignored live_search --nocapture` (indexes the whole
  account and prints the count and time; then a new message, its edit and
  unsend, the server's search and the media page); `flutter test
  test/search_test.dart`.

## Next

- [ ] Check live against the backend on Linux. Done on 31 Oct through the `HTTPS_PROXY` route: Signal view, wide layout with real chats, close to tray, single instance (see "Parity with iOS"). Left: the tray icon on waybar, a notification showing, the installed package
- [ ] AppImage and `.deb`, and arm64 (spec). Not started; whether Flutter can cross-build linux-arm64 from x86_64 is unchecked
- [ ] "Continue on another device" for logins (Hub event plus both apps)
- [x] Cookie logins on WebKitGTK (M2 in the spec), 31 Oct. See "Web logins on Linux"
- [ ] `switchboard://` links on Linux: the desktop entry has no `x-scheme-handler/switchboard` and the runner ignores URL arguments. Nothing sends these links yet (the spec's Hub alerts and the ntfy route), so it waits until something does
- [x] iOS: `pod install` on the Mac, for desktop_drop and pasteboard (done by the iOS builds on 31 Oct)

## Web logins on Linux (31 Oct)

flutter_inappwebview has no Linux web view, so the runner has its own (`app/linux/runner/web_login.cc`, WebKitGTK 4.1, the GTK 3 WebKit that matches Flutter's embedder; the package depends on `webkit2gtk-4.1`). The Dart logic is the same as on iOS: `CookieCollector`, `requestHookScript`, polling cookies and local storage every second, the bridge's extraction script after each load, and submitting once every required value is in and the page is at the bridge's URL, or when Done is tapped. Only the view differs.

- `open` makes a separate window, transient for the main one, on a fresh ephemeral `WebKitWebContext`, so each login starts with an empty cookie jar (a second account on the same network signs in fresh). The bridge's initial cookies go in before the page loads. A hidden step loads in a `GtkOffscreenWindow`: drawn, never on screen.
- The page scripts run at document start in every frame, after a shim that defines `window.flutter_inappwebview.callHandler(name, ...args)` and posts to a WebKit message handler, so the scripts are unchanged.
- `getCookies(url)` returns every cookie whose domain matches the URL's host, HttpOnly included and whatever the path, as flutter_inappwebview's `getCookies(url:)` does on iOS. `evaluateJavascript` returns strings, numbers and booleans as they are, anything else as JSON. Popups load in the same view, as on iOS when nothing handles `onCreateWindow`.
- Native to Dart: load finished, URL changed, script message, and closed. "Closed" is sent for any end of the window Dart didn't ask for, the close button included, and counts as Cancel.
- While the window is open the app shows "Sign in to X in the window that opened", with Done once every required value is in, and Cancel. Cancel and closing the window leave the link screen, which cancels the login with the Hub, as Back does on iOS. The window closes on submit, Cancel and leaving.
- Tests: `test/login_window_test.dart` drives the widget over a fake channel (every source, waiting for the URL, Done, Cancel, closed by the user, hidden, a window that can't open), and `link_screen_test.dart` checks that closing the window leaves and cancels. `integration_test/web_login_test.dart` runs the real window against a local page under Xvfb (`app/tool/linux-web-login-test.sh`): an HttpOnly cookie, a cookie on `Path=/api`, the initial cookie, local storage, a request body field and a header from `fetch`, and the extraction script all reach the submit, which waits for `/home`; a second login's first request carries no cookie from the first; a close request from the close button (`WM_DELETE_WINDOW`) cancels; a hidden login shows no window. It passed three runs in a row.
- Live, 31 Oct: Add account, Instagram, Cookies opened instagram.com in the window from the real bridge step. No sign-in was tried.
- Not checked: Wayland (only X11 under Xvfb), and a real sign-in on any network.
- Xvfb has no window manager, so `xdotool windowquit` (which asks the window manager through `_NET_CLOSE_WINDOW`) does nothing there. The test sends `WM_DELETE_WINDOW` to the window itself with a few lines of Python `ctypes`.

## Parity with iOS (31 Oct, branch `networks`)

Gone through the M1 Done list, this file's Done list and the 31 Oct list on the Linux build. Most of it is shared Dart and Rust, so the checks were the build, the tests and the screens.

- Builds: `flutter analyze` clean; `flutter test` 77 pass and the 2 goldens fail by 3.80% and 2.25%, as before; `flutter build linux --release` builds and the binary starts.
- Checked live against the server, through an `HTTPS_PROXY`: restore and sync; the wide layout with real chats; the sidebar with Notes, the Matrix glyph and Signal's status dot; the Notes view (Note to Self with its + to make it, Signal's Note to Self); the Signal view (the `m.bridge` core fix works on Linux); Accounts grouped by network with Add another; Add account listing Discord, Instagram, Matrix, Signal ("1 linked · add another"), Slack and WhatsApp; Instagram's flow picker and its Cookies step; single instance (a second launch exits and raises the first); close to tray (window_manager's close handler runs and the window hides, also after a second launch); notifications set up without error.
- Checked without the server: the sign-in screen's labels sit inside their boxes (the real app with no session, on a private bus and keyring); login forms use the same theme.
- Not checked: a desktop notification showing (needs a new message), the tray icon on waybar, a chat header naming its account (needs two accounts on one network), recording a voice note, sending anything (no writes to real chats), building the Arch package.
- Different on purpose: push is iOS only (live sync and desktop notifications instead, and no Notifications item in the menu); files open or save instead of the share sheet; the camera shows only where image_picker has one; keyboard shortcuts.
- Gap: `switchboard://` links (see Next).

## Notes

- The goldens in `app/test/goldens` are macOS renders. On Linux they fail by 3.80% and 2.25% (anti-aliasing round every glyph), the same before and after this work.
- Desktop behaviour keys off `defaultTargetPlatform`, which widget tests report as Android, so existing tests keep the phone behaviour. Desktop tests use `TargetPlatformVariant.only(TargetPlatform.linux)`.
- tray_manager is pinned to 0.5.3, the last release that is a normal Linux plugin (0.6 and later build C++ through native-assets hooks). It calls `app_indicator_new`, deprecated in libayatana-appindicator 0.6, so `app/linux/CMakeLists.txt` keeps deprecation warnings from failing the build.
- desktop_drop is pinned to 0.8.4: 0.9 needs `cross_file` 0.4, which file_picker 13 rejects.
- Clipboard images come through pasteboard (GTK) rather than super_clipboard, which would add a second Rust build.
- With no Secret Service on the bus, the app stays on the splash screen while Riverpod retries reading the session. gnome-keyring is an optional dependency of the package.
- A missing local store with a session in the keyring signs that device out (the iOS reinstall rule in `SwitchboardCore::restore`). On Linux that happens if `~/.local/share/com.richarddraycott.switchboard` is removed or `XDG_DATA_HOME` changes.
- To reach the backend from a machine on another tailnet, the core honours `HTTPS_PROXY` (reqwest's system proxy), for both Synapse and the Hub.
- Desktop notifications use `flutter_local_notifications_linux` directly (changed in the merge with `notifications`, 31 Oct): the full `flutter_local_notifications` 22 plugin's iOS code doesn't compile with Xcode 16, and iOS uses push. Same API apart from the constructor and `initialize(settings: LinuxInitializationSettings(...))`. On Linux it sets up without error (31 Oct); a notification showing is not yet rechecked.
