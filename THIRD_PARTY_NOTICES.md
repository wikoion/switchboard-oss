# Third-party notices

Switchboard's own code is AGPL-3.0-or-later (see [LICENSE](LICENSE) and the
README). This file lists the third-party code this repository vendors, patches
or links, the assets it bundles, and the container images the backend runs.
Each licence was read from the package's own licence file or source headers at
the version pinned here: `bridges/matrix/go.sum`, `sb/go.sum`,
`core/Cargo.lock`, `app/pubspec.lock`, `deploy/versions.env` and the
Dockerfiles in `bridges/signal`, `bridges/discord` and `bridges/slack`.

## Vendored or patched

| Component | Where | Licence |
| --- | --- | --- |
| [mautrix-signal](https://github.com/mautrix/signal) v0.2610.0 | `bridges/signal/patches/` (edits to upstream files) and `bridges/signal/overlay/` (new files built into the bridge) | AGPL-3.0-or-later, like the bridge |
| [mautrix-discord](https://github.com/mautrix/discord), branch `megadiscord` at c915e03 | `bridges/discord/patches/` and `bridges/discord/overlay/`, likewise | AGPL-3.0-or-later, like the bridge |
| [mautrix-slack](https://github.com/mautrix/slack) v0.2610.0 | `bridges/slack/patches/` and `bridges/slack/overlay/`, likewise | AGPL-3.0-or-later, like the bridge |
| mautrix bridges' `docker-run.sh` | `bridges/matrix/docker-run.sh` follows its structure | AGPL-3.0-or-later |
| [Cargokit](https://github.com/irondash/cargokit), Copyright 2022 Matej Knopp | `app/rust_builder/cargokit/` | MIT or Apache-2.0, at your option ([LICENSE](app/rust_builder/cargokit/LICENSE)) |
| [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 2.13.0 output | `core/src/frb_generated.rs`, `app/lib/src/rust/`, the `app/rust_builder/` plugin glue | Generated from Switchboard's code; flutter_rust_bridge itself is MIT |
| [freezed](https://pub.dev/packages/freezed) output | `app/lib/src/rust/api/types.freezed.dart` | Generated; freezed is MIT |
| Flutter project template | Runner files under `app/ios/` and `app/linux/` | BSD-3-Clause |

## Linked into the app and bridges

| Component | Version | Used by | Licence |
| --- | --- | --- | --- |
| [RingRTC](https://github.com/signalapp/ringrtc) | 2.74.0 | Signal calls: the Rust crate on Linux (`core/Cargo.toml`); Signal's Swift package and prebuilt `LibRingRTCFfi` on iOS (`app/ios/SwitchboardRingRTC`) | AGPL-3.0-only |
| [libsignal](https://github.com/signalapp/libsignal) (libsignal-core, zkgroup, signal-crypto and others) | v0.99.1 | Through RingRTC (the Signal bridge image builds its own copy; see below) | AGPL-3.0-only |
| WebRTC, prebuilt by Signal for RingRTC | as RingRTC | Through RingRTC | BSD-3-Clause; its own dependencies are listed in RingRTC's `acknowledgments/` |
| [matrix-sdk](https://github.com/matrix-org/matrix-rust-sdk), matrix-sdk-ui, matrix-sdk-base | 0.19.1 | `core/` | Apache-2.0 |
| [vodozemac](https://github.com/matrix-org/vodozemac) | 0.11.1 | Through matrix-sdk | Apache-2.0 |
| [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) crate and Dart package | 2.13.0 | `core/`, `app/` | MIT |
| [media_kit](https://github.com/media-kit/media-kit), media_kit_video, media_kit_libs_video | 1.2.6, 2.0.1, 1.0.7 | Video and voice note playback, the ringtone | MIT |
| libmpv and FFmpeg on iOS, bundled by media_kit_libs_ios_video 1.1.4 from [libmpv-darwin-build](https://github.com/media-kit/libmpv-darwin-build) v0.6.0 ("video-default" build) | mpv and FFmpeg as built there | iOS app | libmpv is built with `-Dgpl=false`: LGPL-2.1-or-later. FFmpeg's libraries report "LGPL version 3 or later" (LGPL-3.0-or-later; no GPL parts). Their dependencies (libass, dav1d, FreeType, FriBidi, HarfBuzz, Mbed TLS, libpng, uchardet, libxml2) keep their own licences; the build scripts are MIT |
| libmpv and FFmpeg on Linux | the system's | Linux app | Not bundled: loaded from the distribution's `mpv` and `ffmpeg` packages, under the distribution's licences for those builds |
| [dbus](https://pub.dev/packages/dbus) (Dart) | 0.7.15 | Linux, through the notification, file picker, drag-and-drop and wakelock plugins | MPL-2.0 |
| [mautrix-go](https://github.com/mautrix/go) (`maunium.net/go/mautrix`) | v0.32.0 | `bridges/matrix` (sb-matrix) | MPL-2.0 |
| `go.mau.fi/util`, `go.mau.fi/zeroconfig` | v0.11.0, v0.2.0 | sb-matrix | MPL-2.0 |
| `maunium.net/go/mauflag` | v1.0.0 | sb-matrix, through mautrix-go's bridge main | GPL-3.0-or-later. Section 13 of GPLv3 allows combining it with AGPL-3.0 code |
| `gopkg.in/yaml.v3` | v3.0.1 | `sb`, the Hub, sb-matrix | MIT and Apache-2.0 |

The remaining dependencies, with their exact versions, are in
`core/Cargo.lock`, `app/pubspec.lock`, `sb/go.mod` and `bridges/matrix/go.mod`;
each package ships its own licence.

## Assets

| Asset | Where | Source and licence |
| --- | --- | --- |
| Network logos | `app/assets/networks/` | [Simple Icons](https://simpleicons.org) 16.36.0, CC0-1.0; LinkedIn and Slack use generic Material Icons glyphs (Apache-2.0) instead, as Simple Icons dropped those brands' logos. CC0 covers the drawings only: the logos and names are trademarks of their owners. See `SOURCE.txt` there |
| App and tray icon glyph | `app/assets/icon/` | Material Icons "forum", [Apache-2.0](https://github.com/google/material-design-icons/blob/master/LICENSE). See `SOURCE.txt` there |
| Note to Self icon glyph | `app/assets/notes/note_to_self.svg` | Material Icons "edit_note", Apache-2.0. See `SOURCE.txt` there |
| Ringtone | `app/assets/sounds/ringtone.ogg` | Generated with FFmpeg for Switchboard; the command is in `SOURCE.txt` there |
| iOS app icons | `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/` | Renders of `app/assets/icon/switchboard.svg`, so Material Icons "forum", Apache-2.0. See `app/assets/icon/SOURCE.txt` |
| iOS launch images | `app/ios/Runner/Assets.xcassets/LaunchImage.imageset/` | Flutter's project template (blank 1-pixel placeholders), BSD-3-Clause |

## Container images the backend runs

This repository doesn't distribute these. `sb` pulls them from their
publishers at run time, or builds them on your machine from upstream source
(the Signal bridge) or from this repository (`sb-matrix`, the Hub). Each image
also contains its base system's packages under their own licences.

| Image | Project | Licence |
| --- | --- | --- |
| `matrixdotorg/synapse` | [Synapse](https://github.com/element-hq/synapse) | AGPL-3.0-only, or an Element commercial licence |
| `matrixdotorg/sygnal` | [Sygnal](https://github.com/element-hq/sygnal) | AGPL-3.0-only, or an Element commercial licence |
| `dock.mau.dev/mautrix/*` (WhatsApp, Meta, Telegram, Twitter, LinkedIn, Google Messages, Bluesky, Google Voice) | [mautrix bridges](https://github.com/mautrix) | AGPL-3.0; most say "or any later version" in their source headers |
| `switchboard/mautrix-signal`, built from `bridges/signal` | mautrix-signal with the patches above | AGPL-3.0-or-later, with libsignal under AGPL-3.0-only |
| `switchboard/mautrix-discord` and `switchboard/mautrix-slack`, built from `bridges/discord` and `bridges/slack` | mautrix-discord and mautrix-slack with the patches above | AGPL-3.0-or-later |
| `postgres` | [PostgreSQL](https://www.postgresql.org/about/licence/) | PostgreSQL License |
| `caddy` | [Caddy](https://github.com/caddyserver/caddy) | Apache-2.0 |
| `tailscale/tailscale` | [Tailscale](https://github.com/tailscale/tailscale) | BSD-3-Clause |
