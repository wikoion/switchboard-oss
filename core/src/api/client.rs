//! The core's handle to one signed-in account: session, sync, chat list,
//! timelines, media and the Hub.

use std::{
    collections::{HashMap, HashSet},
    path::Path,
    sync::{Arc, Mutex as StdMutex},
};

use anyhow::{anyhow, bail, Context, Result};
use eyeball_im::VectorDiff;
use flutter_rust_bridge::frb;
use futures_util::{pin_mut, StreamExt};
use matrix_sdk::{
    attachment::{AttachmentInfo, BaseAudioInfo, BaseFileInfo, BaseImageInfo, BaseVideoInfo},
    authentication::matrix::MatrixSession,
    deserialized_responses::RawAnySyncOrStrippedState,
    media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings},
    reqwest,
    room::edit::EditedContent,
    ruma::{
        api::client::receipt::create_receipt::v3::ReceiptType,
        events::{
            room::{
                message::{RoomMessageEventContent, RoomMessageEventContentWithoutRelation},
                MediaSource,
            },
            AnySyncMessageLikeEvent, AnySyncTimelineEvent, Mentions, StateEventType, SyncMessageLikeEvent,
        },
        EventId, OwnedEventId, OwnedMxcUri, OwnedRoomId, OwnedTransactionId, OwnedUserId, RoomId, UInt,
    },
    store::RoomLoadSettings,
    send_queue::SendHandle,
    Client, Room, RoomHero, RoomMemberships, RoomState,
};
use matrix_sdk_ui::{
    room_list_service::{filters, RoomListItem},
    sync_service::{State as SdkSyncState, SyncService},
    timeline::{
        AttachmentConfig, RoomExt, Timeline, TimelineEventFocusThreadMode, TimelineEventItemId, TimelineFocus,
    },
};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, Mutex, OnceCell, Semaphore};

use crate::{
    api::types::*,
    calls,
    convert::{self, millis},
    index::{self, Indexer},
    sse::SseParser,
    frb_generated::StreamSink,
    runtime,
};

/// What Dart keeps in the Keychain to restore a session.
#[derive(Serialize, Deserialize)]
struct StoredSession {
    homeserver_url: String,
    session: MatrixSession,
}

#[frb(opaque)]
pub struct SwitchboardCore {
    inner: Arc<Inner>,
}

struct Inner {
    client: Client,
    homeserver_url: String,
    sync: OnceCell<Arc<SyncService>>,
    timelines: Mutex<HashMap<OwnedRoomId, Arc<Timeline>>>,
    /// A timeline around one event per room, for opening a search result.
    focused: Mutex<HashMap<OwnedRoomId, (OwnedEventId, Arc<Timeline>)>>,
    /// The replies of each thread that has been opened, by the message
    /// that started it.
    threads: Mutex<HashMap<(OwnedRoomId, OwnedEventId), Arc<Timeline>>>,
    index: Arc<Indexer>,
    /// Networks found so far. Rooms without one aren't kept here, so a
    /// later `m.bridge` still gets picked up.
    networks: StdMutex<HashMap<OwnedRoomId, Network>>,
    /// Room features fetched from the server, for rooms whose state the
    /// sync didn't carry.
    features: StdMutex<HashMap<OwnedRoomId, Option<RoomFeatures>>>,
    /// Rooms whose state is being fetched from the server.
    fetching: StdMutex<HashSet<OwnedRoomId>>,
    fetch_slots: Semaphore,
    /// Rooms whose network a fetch just found, for the chat list.
    resolved: broadcast::Sender<OwnedRoomId>,
    listening: StdMutex<HashSet<OwnedRoomId>>,
    /// When each edited latest message was sent, by its event ID.
    edited_sent: StdMutex<HashMap<OwnedEventId, i64>>,
    /// Rooms whose history is being fetched back to their newest message.
    filling: StdMutex<HashSet<OwnedRoomId>>,
    fill_slots: Semaphore,
    gaps_watched: std::sync::Once,
    http: reqwest::Client,
}

/// What the server's full room state says, for state the sync leaves out.
#[frb(ignore)]
#[derive(Default)]
struct ServerState {
    network: Option<Network>,
    features: Option<RoomFeatures>,
}

/// A network as kept in the store's custom values. `None` means the server
/// said the room isn't bridged.
#[frb(ignore)]
#[derive(Serialize, Deserialize)]
struct SavedNetwork {
    id: String,
    name: String,
    avatar_mxc: Option<String>,
}

/// Global account data naming the Note to Self room.
const NOTE_TO_SELF_TYPE: &str = "app.switchboard.note_to_self";

fn note_to_self_room(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let id = v.get("room_id")?.as_str()?;
    id.starts_with('!').then(|| id.to_owned())
}

fn network_key(room_id: &RoomId) -> String {
    format!("app.switchboard.network.{room_id}")
}

fn store_path(data_dir: &str) -> std::path::PathBuf {
    Path::new(data_dir).join("matrix")
}

impl SwitchboardCore {
    /// Signs in with a password. `server` is the homeserver URL or a name
    /// with a `.well-known` file. Any earlier local store is discarded,
    /// because a new login is a new device.
    pub async fn login(
        server: String,
        username: String,
        password: String,
        device_name: String,
        data_dir: String,
        passphrase: String,
    ) -> Result<SwitchboardCore> {
        runtime::run(async move {
            let store = store_path(&data_dir);
            let _ = tokio::fs::remove_dir_all(&store).await;
            index::remove_files(&index::path_in(&data_dir));
            let client = Client::builder()
                .server_name_or_homeserver_url(server.trim())
                .sqlite_store(&store, Some(&passphrase))
                .build()
                .await
                .context("can't reach the server")?;
            client
                .matrix_auth()
                .login_username(username.trim(), &password)
                .initial_device_display_name(&device_name)
                .send()
                .await?;
            Ok(Self::wrap(client, &data_dir))
        })
        .await
    }

    /// Restores a session saved by [`Self::session_json`].
    pub async fn restore(
        session_json: String,
        data_dir: String,
        passphrase: String,
    ) -> Result<SwitchboardCore> {
        runtime::run(async move {
            let stored: StoredSession = serde_json::from_str(&session_json)?;
            let store = store_path(&data_dir);
            if !tokio::fs::try_exists(&store).await.unwrap_or(false) {
                // iOS keeps the Keychain when an app is deleted, so a
                // reinstall finds a session whose encryption keys are gone.
                // Sign that device out and start again.
                if let Ok(client) = Client::builder().homeserver_url(&stored.homeserver_url).build().await {
                    if client
                        .matrix_auth()
                        .restore_session(stored.session, RoomLoadSettings::default())
                        .await
                        .is_ok()
                    {
                        let _ = client.matrix_auth().logout().await;
                    }
                }
                bail!("the local store is missing; sign in again");
            }
            let client = Client::builder()
                .homeserver_url(&stored.homeserver_url)
                .sqlite_store(store, Some(&passphrase))
                .build()
                .await?;
            client
                .matrix_auth()
                .restore_session(stored.session, RoomLoadSettings::default())
                .await?;
            Ok(Self::wrap(client, &data_dir))
        })
        .await
    }

    fn wrap(client: Client, data_dir: &str) -> SwitchboardCore {
        let homeserver_url = client.homeserver().to_string().trim_end_matches('/').to_owned();
        let resolved = broadcast::channel(256).0;
        // Archiving lives in room account data, which doesn't change a
        // room's info, so the room list wouldn't notice; resend the room.
        let resend = resolved.clone();
        client.add_event_handler(move |ev: matrix_sdk::ruma::serde::Raw<matrix_sdk::ruma::events::AnyRoomAccountDataEvent>, room: Room| {
            let resend = resend.clone();
            async move {
                if ev.get_field::<String>("type").ok().flatten().as_deref() == Some(ARCHIVE_TYPE) {
                    let _ = resend.send(room.room_id().to_owned());
                }
            }
        });
        let index = Indexer::new(client.clone(), open_index(data_dir));
        SwitchboardCore {
            inner: Arc::new(Inner {
                client,
                homeserver_url,
                sync: OnceCell::new(),
                timelines: Mutex::new(HashMap::new()),
                focused: Mutex::new(HashMap::new()),
                threads: Mutex::new(HashMap::new()),
                index,
                networks: StdMutex::new(HashMap::new()),
                features: StdMutex::new(HashMap::new()),
                fetching: StdMutex::new(HashSet::new()),
                fetch_slots: Semaphore::new(4),
                resolved,
                listening: StdMutex::new(HashSet::new()),
                edited_sent: StdMutex::new(HashMap::new()),
                filling: StdMutex::new(HashSet::new()),
                fill_slots: Semaphore::new(4),
                gaps_watched: std::sync::Once::new(),
                http: reqwest::Client::new(),
            }),
        }
    }

    #[frb(sync)]
    pub fn session_json(&self) -> Result<String> {
        let session = self.inner.client.matrix_auth().session().ok_or_else(|| anyhow!("not signed in"))?;
        Ok(serde_json::to_string(&StoredSession {
            homeserver_url: self.inner.homeserver_url.clone(),
            session,
        })?)
    }

    #[frb(sync)]
    pub fn user_id(&self) -> String {
        self.inner.client.user_id().map(|u| u.to_string()).unwrap_or_default()
    }

    #[frb(sync)]
    pub fn homeserver_url(&self) -> String {
        self.inner.homeserver_url.clone()
    }

    /// For the call service, which sends and reads its own events.
    #[frb(ignore)]
    pub(crate) fn matrix_client(&self) -> Client {
        self.inner.client.clone()
    }

    pub async fn start_sync(&self) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.gaps_watched.call_once(|| {
                // Subscribed before the first sync, so none is missed.
                let updates = inner.client.subscribe_to_all_room_updates();
                runtime::spawn(inner.clone().watch_gaps(updates));
                inner.index.start(inner.client.subscribe_to_all_room_updates());
            });
            inner.sync().await?.start().await;
            Ok(())
        })
        .await
    }

    pub async fn stop_sync(&self) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            if let Some(sync) = inner.sync.get() {
                sync.stop().await;
            }
            Ok(())
        })
        .await
    }

    pub async fn logout(&self) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            if let Some(sync) = inner.sync.get() {
                sync.stop().await;
            }
            inner.index.shut_down().await;
            inner.client.matrix_auth().logout().await?;
            Ok(())
        })
        .await
    }

    pub async fn subscribe_sync_status(&self, sink: StreamSink<SyncStatus>) -> Result<()> {
        let inner = self.inner.clone();
        let sync = runtime::run(async move { inner.sync().await }).await?;
        runtime::spawn(async move {
            fn status(state: &SdkSyncState) -> SyncStatus {
                match state {
                    SdkSyncState::Idle => SyncStatus::Idle,
                    SdkSyncState::Running => SyncStatus::Running,
                    SdkSyncState::Offline => SyncStatus::Offline,
                    SdkSyncState::Error(_) => SyncStatus::Error,
                    SdkSyncState::Terminated => SyncStatus::Terminated,
                }
            }
            let mut states = sync.state();
            // The subscriber only yields changes, so a sync already running
            // when the app asked never said so; send where it stands first.
            let first = status(&states.get());
            if sink.add(first.clone()).is_err() {
                return;
            }
            let mut last = Some(first);
            while let Some(state) = states.next().await {
                let status = status(&state);
                if last.as_ref() != Some(&status) {
                    last = Some(status.clone());
                    if sink.add(status).is_err() {
                        break;
                    }
                }
            }
        });
        Ok(())
    }

    /// Streams the chat list: a `Reset` first, then batches of changes.
    /// Spaces (such as the bridges' per-account spaces) are left out.
    pub async fn subscribe_room_list(&self, sink: StreamSink<Vec<RoomListDiff>>) -> Result<()> {
        let inner = self.inner.clone();
        let sync = runtime::run({
            let inner = inner.clone();
            async move { inner.sync().await }
        })
        .await?;
        runtime::spawn(async move {
            let service = sync.room_list_service();
            let all = match service.all_rooms().await {
                Ok(all) => all,
                Err(e) => {
                    let _ = sink.add_error(anyhow!(e));
                    return;
                }
            };
            let (stream, controller) = all.entries_with_dynamic_adapters(5_000);
            controller.set_filter(Box::new(filters::new_filter_all(vec![
                Box::new(filters::new_filter_non_left()),
                Box::new(filters::new_filter_not(Box::new(filters::new_filter_space()))),
            ])));
            pin_mut!(stream);
            // The list's room IDs by index, to resend a room whose network
            // a background fetch found.
            let mut ids = Vec::new();
            let mut resolved = inner.resolved.subscribe();
            loop {
                let out = tokio::select! {
                    diffs = stream.next() => {
                        let Some(diffs) = diffs else { break };
                        let mut out = Vec::with_capacity(diffs.len());
                        for diff in diffs {
                            track_ids(&mut ids, &diff, |r: &RoomListItem| r.room_id().to_owned());
                            out.push(inner.room_diff(diff).await);
                        }
                        out
                    }
                    Ok(room_id) = resolved.recv() => {
                        let Some(index) = ids.iter().position(|id| *id == room_id) else { continue };
                        let Some(room) = inner.client.get_room(&room_id) else { continue };
                        vec![RoomListDiff::Set { index: index as u32, value: inner.summary(room).await }]
                    }
                };
                if sink.add(out).is_err() {
                    break;
                }
            }
        });
        Ok(())
    }

    /// Streams one room's timeline: a `Reset` first, then batches of changes.
    pub async fn subscribe_timeline(
        &self,
        room_id: String,
        sink: StreamSink<Vec<TimelineDiff>>,
    ) -> Result<()> {
        let inner = self.inner.clone();
        let timeline = runtime::run(async move {
            let timeline = inner.timeline(&room_id).await?;
            // The room list syncs one event per room, and a room with more
            // new events comes back "limited", which empties its cached
            // timeline down to the newest message. Subscribing the open
            // chat gets it every event instead, as Element X does.
            let room_id = OwnedRoomId::try_from(room_id.as_str())?;
            inner.sync().await?.room_list_service().reset_and_add_room_subscriptions(&[&room_id]).await;
            anyhow::Ok(timeline)
        })
        .await?;
        stream_timeline(timeline, sink);
        Ok(())
    }

    /// Loads older messages. Returns true once the start of the room is
    /// reached.
    pub async fn paginate_back(&self, room_id: String, count: u16) -> Result<bool> {
        let inner = self.inner.clone();
        runtime::run(async move {
            Ok(inner.timeline(&room_id).await?.paginate_backwards(count).await?)
        })
        .await
    }

    /// Streams the messages around `event_id`, for opening a search result:
    /// a `Reset` first, then batches of changes. It pages both ways with
    /// [`Self::paginate_focused`]; sending still goes to the live timeline.
    pub async fn subscribe_timeline_at(
        &self,
        room_id: String,
        event_id: String,
        sink: StreamSink<Vec<TimelineDiff>>,
    ) -> Result<()> {
        let inner = self.inner.clone();
        let timeline = runtime::run(async move { inner.focused_timeline(&room_id, &event_id).await }).await?;
        stream_timeline(timeline, sink);
        Ok(())
    }

    /// Streams the replies in the thread under `root_id`, oldest first: a
    /// `Reset` first, then batches of changes. The message that started the
    /// thread is the first item once the start is reached.
    pub async fn subscribe_thread(
        &self,
        room_id: String,
        root_id: String,
        sink: StreamSink<Vec<TimelineDiff>>,
    ) -> Result<()> {
        let inner = self.inner.clone();
        let timeline = runtime::run(async move { inner.thread_timeline(&room_id, &root_id).await }).await?;
        stream_timeline(timeline, sink);
        Ok(())
    }

    /// Loads older replies of a thread. Returns true once its start is
    /// reached.
    pub async fn paginate_thread(&self, room_id: String, root_id: String, count: u16) -> Result<bool> {
        let inner = self.inner.clone();
        runtime::run(async move {
            Ok(inner.thread_timeline(&room_id, &root_id).await?.paginate_backwards(count).await?)
        })
        .await
    }

    /// Loads older messages around the focused event, or newer ones with
    /// `forwards`. Returns true once that end of the room is reached.
    pub async fn paginate_focused(&self, room_id: String, event_id: String, forwards: bool, count: u16) -> Result<bool> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let timeline = inner.focused_timeline(&room_id, &event_id).await?;
            Ok(if forwards {
                timeline.paginate_forwards(count).await?
            } else {
                timeline.paginate_backwards(count).await?
            })
        })
        .await
    }

    /// Searches the device's index for messages holding every word of
    /// `query`, each matched as the start of a word, newest first.
    /// `room_id` keeps to one chat, and `since_ms` and `until_ms` to a time
    /// range.
    pub async fn search_messages(
        &self,
        query: String,
        room_id: Option<String>,
        since_ms: Option<i64>,
        until_ms: Option<i64>,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<SearchHit>> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let own = inner.client.user_id().ok_or_else(|| anyhow!("not signed in"))?.to_owned();
            let rows = inner.index.db.search(&index::Query {
                text: &query,
                room_id: room_id.as_deref(),
                since: since_ms,
                until: until_ms,
                offset,
                limit,
            })?;
            Ok(rows
                .into_iter()
                .map(|(row, snippet)| SearchHit { message: index::to_message(row, &own, None), snippet })
                .collect())
        })
        .await
    }

    /// Searches the server for messages the device's index doesn't hold,
    /// such as ones older than its period. Pass the previous page's `next`
    /// to continue.
    pub async fn search_server(
        &self,
        query: String,
        room_id: Option<String>,
        since_ms: Option<i64>,
        until_ms: Option<i64>,
        next: Option<String>,
    ) -> Result<SearchPage> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let own = inner.client.user_id().ok_or_else(|| anyhow!("not signed in"))?.to_owned();
            let (rows, next) =
                inner.index.search_server(&query, room_id.as_deref(), since_ms, until_ms, next).await?;
            let hits = rows
                .into_iter()
                .map(|(row, snippet)| SearchHit { message: index::to_message(row, &own, None), snippet })
                .collect();
            Ok(SearchPage { hits, next })
        })
        .await
    }

    /// A page of a chat's photos and videos, files, or links, newest
    /// first. Pass the previous page's `next` to continue. A page can come
    /// back short (or empty) with a `next` where the index ends and the
    /// server's history begins.
    pub async fn chat_media(&self, room_id: String, tab: MediaTab, cursor: Option<String>, limit: u32) -> Result<MediaPage> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let own = inner.client.user_id().ok_or_else(|| anyhow!("not signed in"))?.to_owned();
            let (rows, next) = inner.index.media_page(&room_id, tab, cursor.as_deref(), limit).await?;
            let items = rows.into_iter().map(|(row, url)| index::to_message(row, &own, url)).collect();
            Ok(MediaPage { items, next })
        })
        .await
    }

    /// Streams how the search index stands: now, then whenever it changes.
    pub async fn subscribe_index_status(&self, sink: StreamSink<IndexStatus>) -> Result<()> {
        let index = self.inner.index.clone();
        runtime::spawn(async move {
            let mut changes = index.subscribe();
            if sink.add(index.status_now()).is_err() {
                return;
            }
            while changes.changed().await.is_ok() {
                let status = changes.borrow_and_update().clone();
                if sink.add(status).is_err() {
                    break;
                }
            }
        });
        Ok(())
    }

    /// How many days back the search index goes; 0 for everything.
    pub async fn set_index_period(&self, days: u32) -> Result<()> {
        let index = self.inner.index.clone();
        runtime::run(async move { index.set_period(days).await }).await
    }

    /// Queues a Markdown text message. It shows at once as a local echo and
    /// is retried by the send queue if the server can't be reached.
    ///
    /// `mentions` are the user IDs the body links to with matrix.to pills;
    /// they go in `m.mentions` so the server and bridges notify them. With
    /// `thread_root` the message goes into the thread under that message.
    pub async fn send_text(
        &self,
        room_id: String,
        body: String,
        mentions: Vec<String>,
        thread_root: Option<String>,
    ) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let timeline = inner.timeline_in(&room_id, thread_root.as_deref()).await?;
            let content = RoomMessageEventContent::text_markdown(body).add_mentions(mentions_of(&mentions)?);
            timeline.send(content.into()).await?;
            Ok(())
        })
        .await
    }

    /// Sends a file through the send queue, as a photo, video, audio or
    /// plain file by its MIME type. `is_voice` marks audio as a voice note
    /// (MSC3245), which bridges send as the network's own voice message.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_file(
        &self,
        room_id: String,
        path: String,
        mime_type: String,
        width: Option<u32>,
        height: Option<u32>,
        duration_ms: Option<u32>,
        is_voice: bool,
        thread_root: Option<String>,
    ) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let timeline = inner.timeline_in(&room_id, thread_root.as_deref()).await?;
            let mime: mime::Mime = mime_type.parse()?;
            let size = UInt::new(tokio::fs::metadata(&path).await?.len());
            let duration = duration_ms.map(|ms| std::time::Duration::from_millis(ms.into()));
            let info = match mime.type_() {
                mime::IMAGE => AttachmentInfo::Image(BaseImageInfo {
                    width: width.map(UInt::from),
                    height: height.map(UInt::from),
                    size,
                    ..Default::default()
                }),
                mime::VIDEO => AttachmentInfo::Video(BaseVideoInfo {
                    width: width.map(UInt::from),
                    height: height.map(UInt::from),
                    duration,
                    size,
                    ..Default::default()
                }),
                mime::AUDIO if is_voice => AttachmentInfo::Voice(BaseAudioInfo { duration, size, ..Default::default() }),
                mime::AUDIO => AttachmentInfo::Audio(BaseAudioInfo { duration, size, ..Default::default() }),
                _ => AttachmentInfo::File(BaseFileInfo { size }),
            };
            let config = AttachmentConfig { info: Some(info), ..Default::default() };
            timeline.send_attachment(std::path::PathBuf::from(path), mime, config).await?;
            Ok(())
        })
        .await
    }

    /// Sends a copy of a message to another chat, through that chat's send
    /// queue. Photos and files keep their uploaded media, so nothing is
    /// uploaded again; the copy drops the reply, thread and mentions.
    pub async fn forward(&self, room_id: String, event_id: String, to_room_id: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let event = inner.room(&room_id)?.load_or_fetch_event(&EventId::parse(&event_id)?, None).await?;
            let AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Original(
                message,
            ))) = event.raw().deserialize()?
            else {
                bail!("only messages can be forwarded");
            };
            let content = RoomMessageEventContent::new(message.content.msgtype);
            inner.timeline(&to_room_id).await?.send(content.into()).await?;
            Ok(())
        })
        .await
    }

    /// Replies to `event_id` with a Markdown text message; within the
    /// thread under `thread_root` when the message replied to is in one.
    pub async fn send_reply(
        &self,
        room_id: String,
        body: String,
        event_id: String,
        mentions: Vec<String>,
        thread_root: Option<String>,
    ) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let timeline = inner.timeline_in(&room_id, thread_root.as_deref()).await?;
            let content =
                RoomMessageEventContentWithoutRelation::text_markdown(body).add_mentions(mentions_of(&mentions)?);
            timeline.send_reply(content, OwnedEventId::try_from(event_id)?).await?;
            Ok(())
        })
        .await
    }

    /// Replaces the text of one of your messages. `id` is an event ID, or a
    /// transaction ID while the message is still sending.
    pub async fn edit_text(&self, room_id: String, id: String, body: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let timeline = inner.timeline_with(&room_id, &id).await?;
            let content = RoomMessageEventContentWithoutRelation::text_markdown(body);
            timeline.edit(&item_id(&id)?, EditedContent::RoomMessage(content)).await?;
            Ok(())
        })
        .await
    }

    /// Unsends a message: redacts it, or drops it if it hasn't gone yet.
    pub async fn redact(&self, room_id: String, id: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.timeline_with(&room_id, &id).await?.redact(&item_id(&id)?, None).await?;
            Ok(())
        })
        .await
    }

    /// Tries a failed send again.
    pub async fn retry_send(&self, room_id: String, transaction_id: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.send_handle(&room_id, &transaction_id).await?.unwedge().await?;
            Ok(())
        })
        .await
    }

    /// Drops a message that hasn't been sent.
    pub async fn cancel_send(&self, room_id: String, transaction_id: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.send_handle(&room_id, &transaction_id).await?.abort().await?;
            Ok(())
        })
        .await
    }

    /// The rooms in a space, from its `m.space.child` state. Bridges keep
    /// one such space per linked account.
    pub async fn space_children(&self, space_id: String) -> Result<Vec<String>> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let space = inner.room(&space_id)?;
            let mut out = Vec::new();
            for raw in space.get_state_events(StateEventType::SpaceChild).await? {
                let json = match &raw {
                    RawAnySyncOrStrippedState::Sync(r) => r.json().get().to_owned(),
                    RawAnySyncOrStrippedState::Stripped(r) => r.json().get().to_owned(),
                };
                if let Some(child) = space_child(&json) {
                    out.push(child);
                }
            }
            Ok(out)
        })
        .await
    }

    /// Chats this device still has as joined but the server doesn't: rooms
    /// deleted on the server, which tells no device. They are dropped from
    /// the local store (gone from the next launch) and returned so the app
    /// can hide them now.
    pub async fn forget_stale_rooms(&self) -> Result<Vec<String>> {
        use matrix_sdk::ruma::api::client::membership::joined_rooms::v3::Request;
        let inner = self.inner.clone();
        runtime::run(async move {
            let on_server: HashSet<OwnedRoomId> =
                inner.client.send(Request::new()).await?.joined_rooms.into_iter().collect();
            let local = inner.client.joined_rooms();
            // An empty answer for a busy account is more likely a server
            // problem than every chat gone; leave the store alone then.
            if on_server.is_empty() && !local.is_empty() {
                return Ok(vec![]);
            }
            let mut stale = Vec::new();
            for room in local {
                if !on_server.contains(room.room_id()) {
                    inner.client.state_store().remove_room(room.room_id()).await?;
                    stale.push(room.room_id().to_string());
                }
            }
            Ok(stale)
        })
        .await
    }

    /// Archives chats, as now, or brings them back. An archived chat
    /// returns to the inbox by itself when someone else writes in it.
    pub async fn set_archived(&self, room_ids: Vec<String>, archived: bool) -> Result<()> {
        use matrix_sdk::ruma::{events::RoomAccountDataEventType, serde::Raw};
        let inner = self.inner.clone();
        runtime::run(async move {
            let now = millis(matrix_sdk::ruma::MilliSecondsSinceUnixEpoch::now());
            let content = if archived { serde_json::json!({ "at_ts": now }) } else { serde_json::json!({}) };
            for id in room_ids {
                let room = inner.room(&id)?;
                let raw = Raw::from_json(serde_json::value::to_raw_value(&content)?);
                room.set_account_data_raw(RoomAccountDataEventType::from(ARCHIVE_TYPE), raw).await?;
                let _ = inner.resolved.send(room.room_id().to_owned());
            }
            Ok(())
        })
        .await
    }

    /// Marks chats read up to their newest message and clears "marked
    /// unread", without opening their timelines, for Read all.
    pub async fn mark_rooms_read(&self, room_ids: Vec<String>) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let mut failed = 0;
            for id in room_ids {
                let result: Result<()> = async {
                    let room = inner.room(&id)?;
                    if room.is_marked_unread() {
                        room.set_unread_flag(false).await?;
                    }
                    read_to_newest(&room).await
                }
                .await;
                if let Err(e) = result {
                    tracing::warn!(%id, "couldn't mark read: {e:#}");
                    failed += 1;
                }
            }
            if failed > 0 {
                bail!("{failed} chats couldn't be marked read");
            }
            Ok(())
        })
        .await
    }

    /// Marks read the chats with no messages at all, only state (a portal
    /// the bridge made with no history), so the join stops counting. The
    /// app has no preview for these, but a chat whose latest event isn't
    /// worked out yet has none either, so this asks the server first.
    pub async fn mark_read_if_no_messages(&self, room_ids: Vec<String>) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            for id in room_ids {
                let result: Result<()> = async {
                    let room = inner.room(&id)?;
                    read_if_no_messages(&room).await
                }
                .await;
                if let Err(e) = result {
                    tracing::warn!(%id, "couldn't mark read: {e:#}");
                }
            }
            Ok(())
        })
        .await
    }

    /// Marks chats unread (`m.marked_unread`), or clears the mark.
    pub async fn set_marked_unread(&self, room_ids: Vec<String>, unread: bool) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            for id in room_ids {
                inner.room(&id)?.set_unread_flag(unread).await?;
            }
            Ok(())
        })
        .await
    }

    /// Moves chats to Low Priority, or back: the `m.lowpriority` tag, which
    /// takes them out of the inbox (and out of the favourites), and a room
    /// push rule that silences them except for mentions of you, which
    /// replies to your messages are too. Taking a chat out removes both.
    pub async fn set_low_priority(&self, room_ids: Vec<String>, low_priority: bool) -> Result<()> {
        use matrix_sdk::notification_settings::RoomNotificationMode;
        let inner = self.inner.clone();
        runtime::run(async move {
            let settings = inner.client.notification_settings().await;
            for id in room_ids {
                let room = inner.room(&id)?;
                // Silence first, so nothing notifies between the two steps.
                if low_priority {
                    settings.set_room_notification_mode(room.room_id(), RoomNotificationMode::MentionsAndKeywordsOnly).await?;
                    room.set_is_low_priority(true, None).await?;
                } else {
                    room.set_is_low_priority(false, None).await?;
                    settings.delete_user_defined_room_rules(room.room_id()).await?;
                }
            }
            Ok(())
        })
        .await
    }

    /// Adds a chat to the favourites, at `order` (0 to 1, lowest first),
    /// or takes it out. Moving one is adding it again with a new order.
    pub async fn set_favourite(&self, room_id: String, favourite: bool, order: Option<f64>) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.room(&room_id)?.set_is_favourite(favourite, order).await?;
            Ok(())
        })
        .await
    }

    /// The Note to Self chat: a room with only you in it.
    /// Its ID is kept in `app.switchboard.note_to_self` account data so
    /// every device opens the same one. With `create`, it is made on first
    /// use (or again if you left it).
    pub async fn note_to_self(&self, create: bool) -> Result<Option<String>> {
        use matrix_sdk::ruma::{
            api::client::room::{create_room::v3::Request, Visibility},
            events::GlobalAccountDataEventType,
            serde::Raw,
        };
        let inner = self.inner.clone();
        runtime::run(async move {
            let kind = GlobalAccountDataEventType::from(NOTE_TO_SELF_TYPE);
            let account = inner.client.account();
            let raw = match account.account_data_raw(kind.clone()).await? {
                Some(raw) => Some(raw),
                None => account.fetch_account_data(kind.clone()).await?,
            };
            let existing = raw.and_then(|r| note_to_self_room(r.json().get()));
            if let Some(id) = existing {
                let left = RoomId::parse(&id)
                    .ok()
                    .and_then(|id| inner.client.get_room(&id))
                    .is_some_and(|r| r.state() == RoomState::Left);
                if !left {
                    return Ok(Some(id));
                }
            }
            if !create {
                return Ok(None);
            }
            let mut request = Request::new();
            request.name = Some("Note to Self".to_owned());
            request.visibility = Visibility::Private;
            request.preset = Some(matrix_sdk::ruma::api::client::room::create_room::v3::RoomPreset::PrivateChat);
            let room = inner.client.create_room(request).await?;
            let id = room.room_id().to_string();
            let content = serde_json::value::to_raw_value(&serde_json::json!({ "room_id": id }))?;
            account.set_account_data_raw(kind, Raw::from_json(content)).await?;
            Ok(Some(id))
        })
        .await
    }

    /// What the room's network supports, or nothing for rooms that aren't
    /// bridged (everything is allowed there).
    pub async fn room_features(&self, room_id: String) -> Result<Option<RoomFeatures>> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let room = inner.room(&room_id)?;
            for raw in room.get_state_events(StateEventType::from("com.beeper.room_features")).await? {
                let json = match &raw {
                    RawAnySyncOrStrippedState::Sync(r) => r.json().get().to_owned(),
                    RawAnySyncOrStrippedState::Stripped(r) => r.json().get().to_owned(),
                };
                if let Some(f) = convert::room_features(&json) {
                    return Ok(Some(f));
                }
            }
            // The room list's sync doesn't carry this state, so ask the
            // server, once per room.
            if let Some(f) = inner.features.lock().unwrap().get(room.room_id()) {
                return Ok(f.clone());
            }
            if room.state() != RoomState::Joined {
                return Ok(None);
            }
            let state = inner.server_state(room.room_id()).await?;
            inner.features.lock().unwrap().insert(room.room_id().to_owned(), state.features.clone());
            Ok(state.features)
        })
        .await
    }

    /// Synapse's preview of a link, or nothing when the page has no title
    /// or description.
    pub async fn link_preview(&self, url: String) -> Result<Option<LinkPreview>> {
        use matrix_sdk::ruma::api::client::authenticated_media::get_media_preview::v1::Request;
        let inner = self.inner.clone();
        runtime::run(async move {
            let response = inner.client.send(Request::new(url.clone())).await?;
            let Some(data) = response.data else { return Ok(None) };
            let og: serde_json::Value = serde_json::from_str(data.get())?;
            Ok(convert::og_preview(url, &og))
        })
        .await
    }

    /// Registers this device for push. Synapse sends each notification,
    /// event ID only, to `gateway_url` (Sygnal), which hands it to APNs
    /// with `pushkey`, the device token. The notification extension then
    /// fetches the message itself, so no text travels through Apple.
    pub async fn set_pusher(
        &self,
        app_id: String,
        pushkey: String,
        gateway_url: String,
        device_name: String,
        lang: String,
    ) -> Result<()> {
        use matrix_sdk::ruma::{
            api::client::push::{PusherIds, PusherInit, PusherKind},
            push::{HttpPusherData, PushFormat},
        };
        let inner = self.inner.clone();
        runtime::run(async move {
            let mut data = HttpPusherData::new(gateway_url);
            data.format = Some(PushFormat::EventIdOnly);
            // Sygnal copies this into the APNs payload. mutable-content lets
            // the extension rewrite the alert; the text is the fallback when
            // the server can't be reached.
            data.data.insert(
                "default_payload".to_owned(),
                serde_json::json!({
                    "aps": {
                        "mutable-content": 1,
                        "alert": { "title": "Switchboard", "body": "New message" },
                        "sound": "default"
                    }
                }),
            );
            let pusher = PusherInit {
                ids: PusherIds::new(pushkey, app_id),
                kind: PusherKind::Http(data),
                app_display_name: "Switchboard".to_owned(),
                device_display_name: device_name,
                profile_tag: None,
                lang,
            };
            inner.client.pusher().set(pusher.into(), false).await?;
            Ok(())
        })
        .await
    }

    pub async fn remove_pusher(&self, app_id: String, pushkey: String) -> Result<()> {
        use matrix_sdk::ruma::api::client::push::PusherIds;
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.client.pusher().delete(PusherIds::new(pushkey, app_id)).await?;
            Ok(())
        })
        .await
    }

    /// The room's joined members, fetched from the server the first time.
    pub async fn members(&self, room_id: String) -> Result<Vec<Member>> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let room = inner.room(&room_id)?;
            Ok(room.members(RoomMemberships::JOIN).await?.iter().map(member).collect())
        })
        .await
    }

    /// Streams who else is typing in the room.
    pub async fn subscribe_typing(&self, room_id: String, sink: StreamSink<Vec<Member>>) -> Result<()> {
        let room = self.inner.room(&room_id)?;
        runtime::spawn(async move {
            let (_guard, mut typing) = room.subscribe_to_typing_notifications();
            while let Ok(user_ids) = typing.recv().await {
                let mut out = Vec::with_capacity(user_ids.len());
                for id in user_ids {
                    match room.get_member_no_sync(&id).await {
                        Ok(Some(m)) => out.push(member(&m)),
                        _ => out.push(Member { user_id: id.to_string(), name: None, avatar_mxc: None }),
                    }
                }
                if sink.add(out).is_err() {
                    break;
                }
            }
        });
        Ok(())
    }

    /// Tells the room you are, or have stopped, typing.
    pub async fn set_typing(&self, room_id: String, typing: bool) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.room(&room_id)?.typing_notice(typing).await?;
            Ok(())
        })
        .await
    }

    pub async fn toggle_reaction(&self, room_id: String, event_id: String, key: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let timeline = inner.timeline_with(&room_id, &event_id).await?;
            let id = TimelineEventItemId::EventId(EventId::parse(&event_id)?);
            timeline.toggle_reaction(&id, &key).await?;
            Ok(())
        })
        .await
    }

    pub async fn mark_read(&self, room_id: String) -> Result<()> {
        let inner = self.inner.clone();
        runtime::run(async move {
            inner.timeline(&room_id).await?.mark_as_read(ReceiptType::Read).await?;
            let room = inner.room(&room_id)?;
            // The timeline shows messages only, and none of the replies in
            // threads, so a chat whose unread is a join, an invite or a
            // reply in a thread stays unread; read up to the server's
            // newest event then.
            if room.num_unread_notifications() > 0 || room.num_unread_messages() > 0 {
                read_to_newest(&room).await?;
            }
            // Opening a chat you marked unread clears the mark.
            if room.is_marked_unread() {
                room.set_unread_flag(false).await?;
            }
            Ok(())
        })
        .await
    }

    /// Fetches media from the homeserver, through the SDK's cache. Pass a
    /// width and height for a thumbnail, or zeros for the original.
    pub async fn media(&self, mxc: String, width: u32, height: u32) -> Result<Vec<u8>> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let format = if width > 0 && height > 0 {
                MediaFormat::Thumbnail(MediaThumbnailSettings::new(UInt::from(width), UInt::from(height)))
            } else {
                MediaFormat::File
            };
            let request = MediaRequestParameters {
                source: MediaSource::Plain(OwnedMxcUri::from(mxc)),
                format,
            };
            Ok(inner.client.media().get_media_content(&request, true).await?)
        })
        .await
    }

    /// A round PNG avatar of exactly `size` pixels, so it's drawn 1:1 with
    /// no clip. Synapse sends its nearest stock thumbnail (a 96 px crop for
    /// a 52 px ask), and Flutter's downscale at draw time is soft, so it's
    /// shrunk here. It asks for a scaled thumbnail at twice the size, which
    /// is never smaller than the avatar, unlike the 96 px crop at 3x. The
    /// circle is cut here too: on Linux Flutter clips without anti-aliasing.
    pub async fn avatar(&self, mxc: String, size: u32) -> Result<Vec<u8>> {
        use matrix_sdk::ruma::api::client::media::get_content_thumbnail::v3::Method;
        let inner = self.inner.clone();
        runtime::run(async move {
            let request = MediaRequestParameters {
                source: MediaSource::Plain(OwnedMxcUri::from(mxc)),
                format: MediaFormat::Thumbnail(MediaThumbnailSettings::with_method(
                    Method::Scale,
                    UInt::from(size * 2),
                    UInt::from(size * 2),
                )),
            };
            let bytes = inner.client.media().get_media_content(&request, true).await?;
            round_avatar(&bytes, size).context("avatar isn't an image")
        })
        .await
    }

    /// Streams the Hub's `/events` as JSON strings, reconnecting with
    /// backoff. Each (re)connection first yields `{"type":"connected"}`, so
    /// the app can refetch what it may have missed.
    pub async fn subscribe_hub_events(&self, sink: StreamSink<String>) -> Result<()> {
        let inner = self.inner.clone();
        runtime::spawn(async move {
            let mut backoff = std::time::Duration::from_secs(1);
            loop {
                match inner.stream_hub_events(&sink).await {
                    // The app stopped listening.
                    Ok(false) => return,
                    Ok(true) => backoff = std::time::Duration::from_secs(1),
                    Err(e) => tracing::info!("hub events: {e:#}"),
                }
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(std::time::Duration::from_secs(60));
            }
        });
        Ok(())
    }

    /// Calls the Hub at `/_switchboard/v1{path}` with this session's token.
    /// Login steps that wait for the phone are long polls, so there is no
    /// timeout.
    pub async fn hub(&self, method: String, path: String, body: Option<String>) -> Result<HubResponse> {
        let inner = self.inner.clone();
        runtime::run(async move {
            let token = inner
                .client
                .access_token()
                .ok_or_else(|| anyhow!("not signed in"))?;
            let url = format!("{}/_switchboard/v1{}", inner.homeserver_url, path);
            let method = reqwest::Method::from_bytes(method.as_bytes())?;
            let mut req = inner.http.request(method, url).bearer_auth(token);
            if let Some(body) = body {
                req = req.header("content-type", "application/json").body(body);
            }
            let resp = req.send().await?;
            let status = resp.status().as_u16();
            let body = resp.text().await?;
            Ok(HubResponse { status, body })
        })
        .await
    }
}

impl Inner {
    async fn sync(&self) -> Result<Arc<SyncService>> {
        let sync = self
            .sync
            .get_or_try_init(|| async {
                SyncService::builder(self.client.clone())
                    .with_offline_mode()
                    .build()
                    .await
                    .map(Arc::new)
            })
            .await?;
        Ok(sync.clone())
    }

    /// Reads one connection to the Hub's event stream. Ok(true) when the
    /// server closed it, Ok(false) when the app stopped listening.
    async fn stream_hub_events(&self, sink: &StreamSink<String>) -> Result<bool> {
        let token = self.client.access_token().ok_or_else(|| anyhow!("not signed in"))?;
        let url = format!("{}/_switchboard/v1/events", self.homeserver_url);
        let mut resp = self.http.get(url).bearer_auth(token).send().await?.error_for_status()?;
        if sink.add(r#"{"type":"connected"}"#.to_owned()).is_err() {
            return Ok(false);
        }
        let mut parser = SseParser::default();
        while let Some(chunk) = resp.chunk().await? {
            for data in parser.feed(&chunk) {
                if sink.add(data).is_err() {
                    return Ok(false);
                }
            }
        }
        Ok(true)
    }

    async fn send_handle(&self, room_id: &str, transaction_id: &str) -> Result<SendHandle> {
        // A message sent into a thread waits in that thread's timeline.
        let mut timelines = vec![self.timeline(room_id).await?];
        timelines.extend(self.opened_threads(room_id).await);
        for timeline in timelines {
            let handle = timeline
                .items()
                .await
                .iter()
                .filter_map(|item| item.as_event())
                .find(|e| e.transaction_id().is_some_and(|t| t.as_str() == transaction_id))
                .and_then(|e| e.local_echo_send_handle());
            if let Some(handle) = handle {
                return Ok(handle);
            }
        }
        Err(anyhow!("that message is no longer waiting to send"))
    }

    fn room(&self, room_id: &str) -> Result<Room> {
        let id = RoomId::parse(room_id)?;
        self.client.get_room(&id).ok_or_else(|| anyhow!("unknown room {room_id}"))
    }

    async fn timeline(&self, room_id: &str) -> Result<Arc<Timeline>> {
        let room = self.room(room_id)?;
        let mut timelines = self.timelines.lock().await;
        if let Some(t) = timelines.get(room.room_id()) {
            return Ok(t.clone());
        }
        // Replies in threads stay out of the chat: they show under the
        // message that started the thread, from `thread_timeline`.
        let timeline = room
            .timeline_builder()
            .with_focus(TimelineFocus::Live { hide_threaded_events: true })
            .event_filter(shown_in_chat)
            .build()
            .await?;
        let timeline = Arc::new(timeline);
        timelines.insert(room.room_id().to_owned(), timeline.clone());
        Ok(timeline)
    }

    /// The replies in the thread under `root_id`, kept once opened.
    async fn thread_timeline(&self, room_id: &str, root_id: &str) -> Result<Arc<Timeline>> {
        let room = self.room(room_id)?;
        let root = OwnedEventId::try_from(root_id)?;
        let key = (room.room_id().to_owned(), root.clone());
        let mut threads = self.threads.lock().await;
        if let Some(t) = threads.get(&key) {
            return Ok(t.clone());
        }
        let timeline = room
            .timeline_builder()
            .with_focus(TimelineFocus::Thread { root_event_id: root })
            .event_filter(shown_in_chat)
            .build()
            .await?;
        let timeline = Arc::new(timeline);
        threads.insert(key, timeline.clone());
        Ok(timeline)
    }

    /// The timeline to send into: the thread's with a `thread_root`, else
    /// the chat's.
    async fn timeline_in(&self, room_id: &str, thread_root: Option<&str>) -> Result<Arc<Timeline>> {
        match thread_root {
            Some(root) => self.thread_timeline(room_id, root).await,
            None => self.timeline(room_id).await,
        }
    }

    /// The timelines of the room's threads that have been opened.
    async fn opened_threads(&self, room_id: &str) -> Vec<Arc<Timeline>> {
        let threads = self.threads.lock().await;
        threads.iter().filter(|((room, _), _)| room.as_str() == room_id).map(|(_, t)| t.clone()).collect()
    }

    /// The timeline around `event_id`. One is kept per room: asking for
    /// another event replaces it.
    async fn focused_timeline(&self, room_id: &str, event_id: &str) -> Result<Arc<Timeline>> {
        let room = self.room(room_id)?;
        let target = OwnedEventId::try_from(event_id)?;
        let mut focused = self.focused.lock().await;
        if let Some((id, t)) = focused.get(room.room_id()) {
            if *id == target {
                return Ok(t.clone());
            }
        }
        let timeline = room
            .timeline_builder()
            .with_focus(TimelineFocus::Event {
                target: target.clone(),
                num_context_events: 30,
                thread_mode: TimelineEventFocusThreadMode::Automatic { hide_threaded_events: true },
            })
            .event_filter(shown_in_chat)
            .build()
            .await?;
        let timeline = Arc::new(timeline);
        focused.insert(room.room_id().to_owned(), (target, timeline.clone()));
        Ok(timeline)
    }

    /// The timeline holding the item `id` (an event or transaction ID): the
    /// focused one or an opened thread's if it's there, otherwise the live
    /// one.
    async fn timeline_with(&self, room_id: &str, id: &str) -> Result<Arc<Timeline>> {
        let live = self.timeline(room_id).await?;
        let room = self.room(room_id)?;
        let mut others: Vec<_> = self.focused.lock().await.get(room.room_id()).map(|(_, t)| t.clone()).into_iter().collect();
        others.extend(self.opened_threads(room_id).await);
        if others.is_empty() {
            return Ok(live);
        }
        let holds = |items: &eyeball_im::Vector<Arc<matrix_sdk_ui::timeline::TimelineItem>>| {
            items.iter().filter_map(|item| item.as_event()).any(|e| {
                e.event_id().is_some_and(|e| e.as_str() == id) || e.transaction_id().is_some_and(|t| t.as_str() == id)
            })
        };
        // The message that starts a thread is in both; the chat's has it
        // with its reactions and edits as the chat shows them.
        if holds(&live.items().await) {
            return Ok(live);
        }
        for t in others {
            if holds(&t.items().await) {
                return Ok(t);
            }
        }
        Ok(live)
    }

    async fn room_diff(self: &Arc<Self>, diff: VectorDiff<RoomListItem>) -> RoomListDiff {
        match diff {
            VectorDiff::Append { values } => RoomListDiff::Append { values: self.summaries(values).await },
            VectorDiff::Clear => RoomListDiff::Clear,
            VectorDiff::PushFront { value } => RoomListDiff::PushFront { value: self.summary(value.into_inner()).await },
            VectorDiff::PushBack { value } => RoomListDiff::PushBack { value: self.summary(value.into_inner()).await },
            VectorDiff::PopFront => RoomListDiff::PopFront,
            VectorDiff::PopBack => RoomListDiff::PopBack,
            VectorDiff::Insert { index, value } => {
                RoomListDiff::Insert { index: index as u32, value: self.summary(value.into_inner()).await }
            }
            VectorDiff::Set { index, value } => {
                RoomListDiff::Set { index: index as u32, value: self.summary(value.into_inner()).await }
            }
            VectorDiff::Remove { index } => RoomListDiff::Remove { index: index as u32 },
            VectorDiff::Truncate { length } => RoomListDiff::Truncate { length: length as u32 },
            VectorDiff::Reset { values } => RoomListDiff::Reset { values: self.summaries(values).await },
        }
    }

    async fn summaries(self: &Arc<Self>, rooms: eyeball_im::Vector<RoomListItem>) -> Vec<RoomSummary> {
        let mut out = Vec::with_capacity(rooms.len());
        for room in rooms {
            out.push(self.summary(room.into_inner()).await);
        }
        out
    }

    async fn summary(self: &Arc<Self>, room: Room) -> RoomSummary {
        let id = room.room_id().to_owned();

        // The latest event is only tracked for rooms we ask about.
        let newly_listening = self.listening.lock().unwrap().insert(id.clone());
        if newly_listening {
            let _ = self.client.latest_events().await.listen_to_room(&id).await;
        }

        let name = match room.cached_display_name() {
            Some(n) => n.to_string(),
            None => room.display_name().await.map(|n| n.to_string()).unwrap_or_else(|_| id.to_string()),
        };
        let (preview, preview_ts) = match convert::preview(room.latest_event().await) {
            Some((p, ts)) => (Some(p), Some(ts)),
            None => (None, None),
        };
        // The SDK hands back an edit in place of the message it edits, dated
        // when it was edited. Bridges edit old media messages when you link
        // a network, so date the chat by the message itself.
        let preview_ts = match self.edited_message_ts(&room).await {
            Some(ts) => Some(ts),
            None => preview_ts,
        };
        let dm_user_ids: Vec<String> = room.direct_targets().iter().map(|t| t.as_str().to_owned()).collect();
        let info = room.clone_info();
        let heroes = info.heroes();

        RoomSummary {
            id: id.to_string(),
            name,
            avatar_mxc: room.avatar_url().map(|u| u.to_string()).or_else(|| dm_avatar(heroes, &dm_user_ids)),
            network: self.network(&room).await,
            is_dm: room.is_direct().await.unwrap_or(false),
            member_count: u32::try_from(room.joined_members_count()).unwrap_or(u32::MAX),
            hero_user_ids: heroes.iter().map(|h| h.user_id.to_string()).collect(),
            dm_user_ids,
            is_invite: room.state() == RoomState::Invited,
            is_favourite: room.is_favourite(),
            favourite_order: if room.is_favourite() { favourite_order(&room).await } else { None },
            is_low_priority: room.is_low_priority(),
            is_marked_unread: room.is_marked_unread(),
            archived_at: archived_at(&room).await,
            preview,
            timestamp_ms: preview_ts.or_else(|| room.latest_event_timestamp().map(millis)),
            // Counted on the device from your read receipts and push rules:
            // Synapse's sliding sync always sends zero for these.
            unread_count: u32::try_from(room.num_unread_notifications()).unwrap_or(u32::MAX),
            unread_messages: u32::try_from(room.num_unread_messages()).unwrap_or(u32::MAX),
            mention_count: u32::try_from(room.num_unread_mentions()).unwrap_or(u32::MAX),
        }
    }

    /// The chat list syncs only each chat's newest event. After time away
    /// (an iPhone app in the background) a chat with several new events
    /// gets just the last, and the messages before it are left in a gap.
    /// When that last event isn't a message (a reaction, a bridge's
    /// delivery receipt), the SDK keeps the chat's old latest message, so
    /// the chat keeps its old preview and place. This fetches those chats'
    /// history back to a message; the SDK then works out the latest
    /// message again, and the chat list gets the room.
    async fn watch_gaps(self: Arc<Self>, mut updates: broadcast::Receiver<matrix_sdk::sync::RoomUpdates>) {
        loop {
            match updates.recv().await {
                Ok(update) => {
                    for (room_id, joined) in update.joined {
                        let timeline = &joined.timeline;
                        if timeline.limited && !timeline.events.iter().any(|e| is_message(e.raw())) {
                            let newest = timeline.events.last().and_then(|e| e.event_id()).map(ToOwned::to_owned);
                            self.clone().fill_gap(room_id, newest);
                        }
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => tracing::warn!("missed {n} syncs looking for gaps"),
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    }

    /// Fetches the room's history, newest first, until it holds a message.
    fn fill_gap(self: Arc<Self>, room_id: OwnedRoomId, newest: Option<OwnedEventId>) {
        if !self.filling.lock().unwrap().insert(room_id.clone()) {
            return;
        }
        let inner = self.clone();
        runtime::spawn(async move {
            let result: Result<()> = async {
                let _slot = inner.fill_slots.acquire().await?;
                let room = inner.client.get_room(&room_id).ok_or_else(|| anyhow!("unknown room"))?;
                let (cache, _handles) = room.event_cache().await?;
                // The event cache takes the same sync on its own task: wait
                // for it, or this would look at the events from before.
                if let Some(id) = &newest {
                    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
                    while cache.find_event(id).await?.is_none() {
                        if tokio::time::Instant::now() > deadline {
                            bail!("the sync's events never reached the event cache");
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    }
                }
                // Without a gap, the message is already in memory.
                if cache.rfind_map_event_in_memory_by(|e| is_message(e.raw()).then_some(())).await?.is_some() {
                    return Ok(());
                }
                tracing::debug!(%room_id, "fetching history back to the newest message");
                let pagination = cache.pagination();
                // The first batch may only load the gap from the store; the
                // ones after fetch from the server.
                for _ in 0..5 {
                    let batch = pagination.run_backwards_once(30).await?;
                    if batch.reached_start || batch.events.iter().any(|e| is_message(e.raw())) {
                        break;
                    }
                }
                Ok(())
            }
            .await;
            inner.filling.lock().unwrap().remove(&room_id);
            if let Err(e) = result {
                tracing::warn!(%room_id, "couldn't fill the gap before the newest event: {e:#}");
            }
        });
    }

    /// When the message was sent, if the room's latest event is an edit of
    /// it. Looked up once per message, from the event cache or the server.
    async fn edited_message_ts(&self, room: &Room) -> Option<i64> {
        use matrix_sdk_base::latest_event::LatestEventValue as BaseLatest;
        let BaseLatest::Remote(ev) = matrix_sdk::BaseRoom::latest_event(room) else {
            return None;
        };
        let relation = ev.raw().get_field::<serde_json::Value>("content").ok().flatten()?.get("m.relates_to")?.clone();
        if relation.get("rel_type")?.as_str()? != "m.replace" {
            return None;
        }
        let original = OwnedEventId::try_from(relation.get("event_id")?.as_str()?).ok()?;
        if let Some(ts) = self.edited_sent.lock().unwrap().get(&original) {
            return Some(*ts);
        }
        let event = room.load_or_fetch_event(&original, None).await.ok()?;
        let ts = event.raw().get_field::<i64>("origin_server_ts").ok().flatten()?;
        self.edited_sent.lock().unwrap().insert(original, ts);
        Some(ts)
    }

    /// The network a portal room belongs to, from its `m.bridge` state.
    /// The room list's sync doesn't carry `m.bridge`, so when the store has
    /// none and the server hasn't been asked, this starts a fetch and
    /// returns None; the list gets the room again once the fetch finds it.
    async fn network(self: &Arc<Self>, room: &Room) -> Option<Network> {
        let id = room.room_id();
        if let Some(n) = self.networks.lock().unwrap().get(id) {
            return Some(n.clone());
        }
        let found = match stored_bridge_state(room).await {
            Some(n) => Some(n),
            None => match self.saved_network(id).await {
                Some(saved) => saved,
                None => {
                    if room.state() == RoomState::Joined {
                        self.fetch_room_state(id.to_owned());
                    }
                    None
                }
            },
        };
        if let Some(n) = &found {
            self.networks.lock().unwrap().insert(id.to_owned(), n.clone());
        }
        found
    }

    /// Fetches a room's state from the server in the background, a few
    /// rooms at a time, then saves its network and tells the chat list.
    fn fetch_room_state(self: &Arc<Self>, room_id: OwnedRoomId) {
        if !self.fetching.lock().unwrap().insert(room_id.clone()) {
            return;
        }
        let inner = self.clone();
        runtime::spawn(async move {
            let result: Result<ServerState> = async {
                let _slot = inner.fetch_slots.acquire().await?;
                inner.server_state(&room_id).await
            }
            .await;
            inner.fetching.lock().unwrap().remove(&room_id);
            match result {
                Ok(state) => {
                    inner.save_network(&room_id, state.network.as_ref()).await;
                    inner.features.lock().unwrap().insert(room_id.clone(), state.features);
                    if let Some(n) = state.network {
                        inner.networks.lock().unwrap().insert(room_id.clone(), n);
                        let _ = inner.resolved.send(room_id);
                    }
                }
                // Tried again on the room's next update.
                Err(e) => tracing::warn!(%room_id, "couldn't fetch room state: {e:#}"),
            }
        });
    }

    async fn server_state(&self, room_id: &RoomId) -> Result<ServerState> {
        use matrix_sdk::ruma::api::client::state::get_state_events::v3::Request;
        let response = self.client.send(Request::new(room_id.to_owned())).await?;
        Ok(read_room_state(response.room_state.iter().map(|raw| raw.json().get())))
    }

    /// What an earlier fetch found: Some(None) when the room isn't bridged,
    /// None when the server hasn't been asked.
    async fn saved_network(&self, room_id: &RoomId) -> Option<Option<Network>> {
        let bytes = self
            .client
            .state_store()
            .get_custom_value(network_key(room_id).as_bytes())
            .await
            .ok()??;
        let saved: Option<SavedNetwork> = serde_json::from_slice(&bytes).ok()?;
        Some(saved.map(|s| Network { id: s.id, name: s.name, avatar_mxc: s.avatar_mxc }))
    }

    async fn save_network(&self, room_id: &RoomId, network: Option<&Network>) {
        let saved = network.map(|n| SavedNetwork { id: n.id.clone(), name: n.name.clone(), avatar_mxc: n.avatar_mxc.clone() });
        let Ok(bytes) = serde_json::to_vec(&saved) else { return };
        if let Err(e) = self.client.state_store().set_custom_value_no_read(network_key(room_id).as_bytes(), bytes).await {
            tracing::warn!(%room_id, "couldn't save network: {e}");
        }
    }
}

/// The image cut to a square and sized to `size` pixels with Lanczos, then
/// lightly sharpened to win back the edges shrinking softens, then cut
/// round with a one-pixel soft edge in the alpha channel, as a PNG. None
/// when it can't be decoded.
fn round_avatar(bytes: &[u8], size: u32) -> Option<Vec<u8>> {
    let image = image::load_from_memory(bytes).ok()?;
    let mut round = image
        .resize_to_fill(size, size, image::imageops::FilterType::Lanczos3)
        .unsharpen(0.5, 0)
        .into_rgba8();
    let r = size as f32 / 2.0;
    for (x, y, pixel) in round.enumerate_pixels_mut() {
        // How much of the pixel is inside the circle, from its centre's
        // distance to the edge.
        let d = (x as f32 + 0.5 - r).hypot(y as f32 + 0.5 - r);
        let inside = (r - d + 0.5).clamp(0.0, 1.0);
        pixel[3] = (pixel[3] as f32 * inside).round() as u8;
    }
    let mut png = Vec::new();
    round.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).ok()?;
    Some(png)
}

/// Chats show messages only: no joins, leaves or room settings. Signal
/// call signalling is for the call service, not the chat.
fn shown_in_chat(
    event: &AnySyncTimelineEvent,
    _rules: &matrix_sdk::ruma::room_version_rules::RoomVersionRules,
) -> bool {
    matches!(event, AnySyncTimelineEvent::MessageLike(_)) && event.event_type().to_string() != calls::EVENT_TYPE
}

/// Opens the search index, starting a new one if the file won't open
/// (corrupt, say), or keeping it in memory if that fails too.
fn open_index(data_dir: &str) -> index::Db {
    let path = index::path_in(data_dir);
    match index::Db::open(&path) {
        Ok(db) => db,
        Err(e) => {
            tracing::warn!("starting a new search index: {e:#}");
            index::remove_files(&path);
            index::Db::open(&path).unwrap_or_else(|e| {
                tracing::warn!("keeping the search index in memory: {e:#}");
                index::Db::open_in_memory().expect("in-memory SQLite")
            })
        }
    }
}

/// Sends a read receipt for the room's newest event: the latest one this
/// device knows, or, when it knows none (a chat with no messages yet, a
/// space), the newest the server has.
async fn read_to_newest(room: &Room) -> Result<()> {
    use matrix_sdk::{room::MessagesOptions, ruma::events::receipt::ReceiptThread, BaseRoom};
    use matrix_sdk_base::latest_event::LatestEventValue as BaseLatest;
    let mut newest = match BaseRoom::latest_event(room) {
        BaseLatest::Remote(ev) => ev.event_id().map(ToOwned::to_owned),
        BaseLatest::LocalHasBeenSent { event_id, .. } => Some(event_id),
        _ => None,
    };
    if newest.is_none() || room.num_unread_notifications() > 0 {
        let mut options = MessagesOptions::backward();
        options.limit = UInt::from(1u32);
        if let Some(ev) = room.messages(options).await?.chunk.first() {
            newest = ev.event_id().map(ToOwned::to_owned);
        }
    }
    if let Some(event_id) = newest {
        room.send_single_receipt(ReceiptType::Read, ReceiptThread::Unthreaded, event_id).await?;
    }
    Ok(())
}

/// Whether the SDK can take the event as a chat's latest message: a
/// message (not an edit), sticker, poll or call. Reactions, redactions,
/// edits, state and the bridges' delivery receipts aren't.
fn is_message(raw: &matrix_sdk::ruma::serde::Raw<AnySyncTimelineEvent>) -> bool {
    if raw.get_field::<serde_json::Value>("state_key").ok().flatten().is_some() {
        return false;
    }
    let kind = raw.get_field::<String>("type").ok().flatten().unwrap_or_default();
    let content = raw.get_field::<serde_json::Value>("content").ok().flatten().unwrap_or_default();
    match kind.as_str() {
        "m.room.message" => {
            content.get("msgtype").and_then(|t| t.as_str()).is_some_and(|t| t != "m.key.verification.request")
                && content.pointer("/m.relates_to/rel_type").and_then(|t| t.as_str()) != Some("m.replace")
        }
        "m.sticker" | "org.matrix.msc3381.poll.start" | "m.call.invite" | "m.rtc.notification" => content.as_object().is_some_and(|c| !c.is_empty()),
        _ => false,
    }
}

/// Sends a read receipt for the room's newest event only if none of its
/// newest 20 events is a message.
async fn read_if_no_messages(room: &Room) -> Result<()> {
    use matrix_sdk::{room::MessagesOptions, ruma::events::receipt::ReceiptThread};
    let mut options = MessagesOptions::backward();
    options.limit = UInt::from(20u32);
    let chunk = room.messages(options).await?.chunk;
    let is_message = |ev: &matrix_sdk::deserialized_responses::TimelineEvent| {
        let raw = ev.raw();
        let state = raw.get_field::<serde_json::Value>("state_key").ok().flatten().is_some();
        let kind = raw.get_field::<String>("type").ok().flatten().unwrap_or_default();
        !state && kind != "m.reaction" && kind != "m.room.redaction"
    };
    if chunk.iter().any(is_message) {
        return Ok(());
    }
    if let Some(event_id) = chunk.first().and_then(|ev| ev.event_id()) {
        tracing::info!(room = %room.room_id(), "marking read: no messages");
        room.send_single_receipt(ReceiptType::Read, ReceiptThread::Unthreaded, event_id.to_owned()).await?;
    }
    Ok(())
}

/// Room account data marking a chat archived, as `{at_ts}`; `{}` when not.
const ARCHIVE_TYPE: &str = "app.switchboard.inbox.done";

async fn archived_at(room: &Room) -> Option<i64> {
    use matrix_sdk::ruma::events::RoomAccountDataEventType;
    let raw = room.account_data(RoomAccountDataEventType::from(ARCHIVE_TYPE)).await.ok()??;
    let v: serde_json::Value = serde_json::from_str(raw.json().get()).ok()?;
    v["content"]["at_ts"].as_i64()
}

async fn favourite_order(room: &Room) -> Option<f64> {
    use matrix_sdk::ruma::events::tag::TagName;
    room.tags().await.ok()??.get(&TagName::Favorite)?.order
}

/// A DM with no picture of its own shows the other person's, as the
/// server's room summary gives it.
fn dm_avatar(heroes: &[RoomHero], dm_user_ids: &[String]) -> Option<String> {
    heroes
        .iter()
        .filter(|h| dm_user_ids.iter().any(|id| id == h.user_id.as_str()))
        .find_map(|h| h.avatar_url.as_ref())
        .map(|u| u.to_string())
}

/// The network from `m.bridge` state already in the store.
async fn stored_bridge_state(room: &Room) -> Option<Network> {
    for kind in ["m.bridge", "uk.half-shot.bridge"] {
        let Ok(events) = room.get_state_events(StateEventType::from(kind)).await else { continue };
        for raw in events {
            let json = match &raw {
                RawAnySyncOrStrippedState::Sync(r) => r.json().get().to_owned(),
                RawAnySyncOrStrippedState::Stripped(r) => r.json().get().to_owned(),
            };
            if let Some(n) = parse_bridge_state(&json) {
                return Some(n);
            }
        }
    }
    None
}

/// Picks the network and features out of a room's full state, as JSON
/// events.
fn read_room_state<'a>(events: impl Iterator<Item = &'a str>) -> ServerState {
    let mut state = ServerState::default();
    for json in events {
        let kind = serde_json::from_str::<serde_json::Value>(json)
            .ok()
            .and_then(|v| v["type"].as_str().map(str::to_owned));
        match kind.as_deref() {
            Some("m.bridge" | "uk.half-shot.bridge") if state.network.is_none() => {
                state.network = parse_bridge_state(json);
            }
            Some("com.beeper.room_features") if state.features.is_none() => {
                state.features = convert::room_features(json);
            }
            _ => {}
        }
    }
    state
}

/// Applies a chat list change to the list's room IDs.
fn track_ids<T>(ids: &mut Vec<OwnedRoomId>, diff: &VectorDiff<T>, id: impl Fn(&T) -> OwnedRoomId) {
    match diff {
        VectorDiff::Append { values } => ids.extend(values.iter().map(&id)),
        VectorDiff::Clear => ids.clear(),
        VectorDiff::PushFront { value } => ids.insert(0, id(value)),
        VectorDiff::PushBack { value } => ids.push(id(value)),
        VectorDiff::PopFront => {
            if !ids.is_empty() {
                ids.remove(0);
            }
        }
        VectorDiff::PopBack => {
            ids.pop();
        }
        VectorDiff::Insert { index, value } => ids.insert(*index, id(value)),
        VectorDiff::Set { index, value } => ids[*index] = id(value),
        VectorDiff::Remove { index } => {
            ids.remove(*index);
        }
        VectorDiff::Truncate { length } => ids.truncate(*length),
        VectorDiff::Reset { values } => *ids = values.iter().map(&id).collect(),
    }
}

fn mentions_of(user_ids: &[String]) -> Result<Mentions> {
    let ids = user_ids.iter().map(|id| OwnedUserId::try_from(id.as_str())).collect::<Result<Vec<_>, _>>()?;
    Ok(Mentions::with_user_ids(ids))
}

fn member(m: &matrix_sdk::room::RoomMember) -> Member {
    Member {
        user_id: m.user_id().to_string(),
        name: m.display_name().map(str::to_owned),
        avatar_mxc: m.avatar_url().map(|u| u.to_string()),
    }
}

/// Event IDs start with `$`; anything else is a local transaction ID.
fn item_id(id: &str) -> Result<TimelineEventItemId> {
    Ok(if id.starts_with('$') {
        TimelineEventItemId::EventId(EventId::parse(id)?)
    } else {
        TimelineEventItemId::TransactionId(OwnedTransactionId::from(id))
    })
}

/// The child room ID of an `m.space.child` event, unless it was removed
/// (empty content, so no `via`).
fn space_child(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let has_via = v["content"]["via"].as_array().is_some_and(|via| !via.is_empty());
    has_via.then(|| v["state_key"].as_str().map(str::to_owned)).flatten()
}

fn parse_bridge_state(json: &str) -> Option<Network> {
    #[derive(Deserialize)]
    struct Event {
        content: Content,
    }
    #[derive(Deserialize)]
    struct Content {
        protocol: Protocol,
    }
    #[derive(Deserialize)]
    struct Protocol {
        id: String,
        displayname: Option<String>,
        avatar_url: Option<String>,
    }
    let p = serde_json::from_str::<Event>(json).ok()?.content.protocol;
    Some(Network {
        name: p.displayname.unwrap_or_else(|| p.id.clone()),
        id: p.id,
        avatar_mxc: p.avatar_url,
    })
}

/// Sends a timeline to Dart: a `Reset` with what it holds, then batches of
/// changes until Dart stops listening.
fn stream_timeline(timeline: Arc<Timeline>, sink: StreamSink<Vec<TimelineDiff>>) {
    runtime::spawn(async move {
        let (items, stream) = timeline.subscribe().await;
        let reset = TimelineDiff::Reset {
            values: items.iter().map(|i| convert::timeline_item(i)).collect(),
        };
        if sink.add(vec![reset]).is_err() {
            return;
        }
        pin_mut!(stream);
        while let Some(diffs) = stream.next().await {
            let out = diffs.into_iter().map(timeline_diff).collect();
            if sink.add(out).is_err() {
                break;
            }
        }
    });
}

fn timeline_diff(diff: VectorDiff<Arc<matrix_sdk_ui::timeline::TimelineItem>>) -> TimelineDiff {
    let c = |i: Arc<matrix_sdk_ui::timeline::TimelineItem>| convert::timeline_item(&i);
    match diff {
        VectorDiff::Append { values } => TimelineDiff::Append { values: values.into_iter().map(c).collect() },
        VectorDiff::Clear => TimelineDiff::Clear,
        VectorDiff::PushFront { value } => TimelineDiff::PushFront { value: c(value) },
        VectorDiff::PushBack { value } => TimelineDiff::PushBack { value: c(value) },
        VectorDiff::PopFront => TimelineDiff::PopFront,
        VectorDiff::PopBack => TimelineDiff::PopBack,
        VectorDiff::Insert { index, value } => TimelineDiff::Insert { index: index as u32, value: c(value) },
        VectorDiff::Set { index, value } => TimelineDiff::Set { index: index as u32, value: c(value) },
        VectorDiff::Remove { index } => TimelineDiff::Remove { index: index as u32 },
        VectorDiff::Truncate { length } => TimelineDiff::Truncate { length: length as u32 },
        VectorDiff::Reset { values } => TimelineDiff::Reset { values: values.into_iter().map(c).collect() },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_mautrix_bridge_state() {
        let json = r#"{"type":"m.bridge","state_key":"x","content":{"bridgebot":"@whatsappbot:switchboard.internal","protocol":{"id":"whatsapp","displayname":"WhatsApp","avatar_url":"mxc://maunium.net/NeXNQarUbrlYBiPCpprYsRqr"},"channel":{"id":"123"}}}"#;
        let n = parse_bridge_state(json).unwrap();
        assert_eq!(n.id, "whatsapp");
        assert_eq!(n.name, "WhatsApp");
        assert!(n.avatar_mxc.is_some());
    }

    #[test]
    fn avatars_are_cut_round_at_size() {
        let encode = |w, h| {
            let mut out = Vec::new();
            image::DynamicImage::new_rgb8(w, h)
                .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Jpeg)
                .unwrap();
            out
        };
        let png = round_avatar(&encode(320, 240), 52).unwrap();
        let back = image::load_from_memory(&png).unwrap().into_rgba8();
        assert_eq!((back.width(), back.height()), (52, 52));
        let alpha = |x, y| back.get_pixel(x, y)[3];
        assert_eq!(alpha(0, 0), 0, "corners are cut away");
        assert_eq!(alpha(26, 26), 255, "the middle is solid");
        // On the diagonal the edge fades over a pixel, as Flutter draws a
        // circle, rather than stepping from 0 to 255 like a hard clip.
        let soft = (0..52u32).filter(|&i| (1..255).contains(&alpha(i, i))).count();
        assert!(soft >= 2, "no soft edge on the diagonal");
        let small = round_avatar(&encode(32, 32), 52).unwrap();
        let back = image::load_from_memory(&small).unwrap();
        assert_eq!((back.width(), back.height()), (52, 52), "smaller images are enlarged");
        assert!(round_avatar(b"not an image", 52).is_none());
    }

    #[test]
    fn only_messages_end_a_gap_fill() {
        let raw = |json: &str| matrix_sdk::ruma::serde::Raw::<AnySyncTimelineEvent>::from_json_string(json.into()).unwrap();
        let yes = [
            r#"{"type":"m.room.message","content":{"msgtype":"m.text","body":"hi"}}"#,
            r#"{"type":"m.room.message","content":{"msgtype":"m.text","body":"> quoted","m.relates_to":{"m.in_reply_to":{"event_id":"$a"}}}}"#,
            r#"{"type":"m.sticker","content":{"body":"cat","url":"mxc://x/y","info":{}}}"#,
            r#"{"type":"org.matrix.msc3381.poll.start","content":{"org.matrix.msc3381.poll.start":{}}}"#,
        ];
        let no = [
            r#"{"type":"m.reaction","content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$a","key":"👍"}}}"#,
            r#"{"type":"m.room.message","content":{"msgtype":"m.text","body":"* fixed","m.new_content":{"msgtype":"m.text","body":"fixed"},"m.relates_to":{"rel_type":"m.replace","event_id":"$a"}}}"#,
            r#"{"type":"m.room.message","content":{},"unsigned":{"redacted_because":{}}}"#,
            r#"{"type":"m.room.redaction","redacts":"$a","content":{}}"#,
            r#"{"type":"com.beeper.message_send_status","content":{"status":"SUCCESS"}}"#,
            r#"{"type":"org.matrix.msc3381.poll.response","content":{}}"#,
            r#"{"type":"m.room.member","state_key":"@a:x","content":{"membership":"join"}}"#,
        ];
        for json in yes {
            assert!(is_message(&raw(json)), "{json}");
        }
        for json in no {
            assert!(!is_message(&raw(json)), "{json}");
        }
    }

    #[test]
    fn space_children_skip_removed_ones() {
        let kept = r#"{"type":"m.space.child","state_key":"!a:switchboard.internal","content":{"via":["switchboard.internal"]}}"#;
        let removed = r#"{"type":"m.space.child","state_key":"!b:switchboard.internal","content":{}}"#;
        assert_eq!(space_child(kept).as_deref(), Some("!a:switchboard.internal"));
        assert_eq!(space_child(removed), None);
    }

    #[test]
    fn ignores_other_state() {
        assert!(parse_bridge_state(r#"{"content":{"name":"x"}}"#).is_none());
    }

    #[test]
    fn full_room_state_gives_network_and_features() {
        let events = [
            r#"{"type":"m.room.name","state_key":"","content":{"name":"Alice"}}"#,
            r#"{"type":"uk.half-shot.bridge","state_key":"s","content":{"protocol":{"id":"signal","displayname":"Signal"}}}"#,
            r#"{"type":"com.beeper.room_features","state_key":"s","content":{"reply":2,"edit":0}}"#,
        ];
        let state = read_room_state(events.into_iter());
        assert_eq!(state.network.map(|n| n.id).as_deref(), Some("signal"));
        assert!(state.features.is_some());

        let plain = read_room_state([r#"{"type":"m.room.name","state_key":"","content":{"name":"x"}}"#].into_iter());
        assert!(plain.network.is_none() && plain.features.is_none());
    }

    #[test]
    fn room_ids_follow_list_changes() {
        let id = |s: &&str| OwnedRoomId::try_from(format!("!{s}:x")).unwrap();
        let mut ids = Vec::new();
        let apply = |ids: &mut Vec<OwnedRoomId>, d: VectorDiff<&str>| track_ids(ids, &d, id);
        apply(&mut ids, VectorDiff::Reset { values: ["a", "b"].into_iter().collect() });
        apply(&mut ids, VectorDiff::PushFront { value: "c" });
        apply(&mut ids, VectorDiff::Insert { index: 1, value: "d" });
        apply(&mut ids, VectorDiff::Remove { index: 3 });
        apply(&mut ids, VectorDiff::Set { index: 0, value: "e" });
        apply(&mut ids, VectorDiff::PushBack { value: "f" });
        let names: Vec<_> = ids.iter().map(|i| i.as_str().to_owned()).collect();
        assert_eq!(names, ["!e:x", "!d:x", "!a:x", "!f:x"]);
    }

    /// Against the live server: sign in as a throwaway device, then send,
    /// reply, edit and unsend in a test room, and sign out.
    ///   SB_TEST_SERVER=https://switchboard.<tailnet>.ts.net \
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... SB_TEST_ROOM='!id:switchboard.internal' \
    ///     cargo test -- --ignored live_send
    /// SB_TEST_SERVER is needed by every live test here.
    #[tokio::test]
    #[ignore]
    async fn live_send_round_trip() {
        use std::time::{Duration, Instant};

        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let room_id = std::env::var("SB_TEST_ROOM").expect("SB_TEST_ROOM");
        let dir = std::env::temp_dir().join(format!("sb-core-test-{}", std::process::id()));

        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        core.start_sync().await.expect("sync");

        let deadline = Instant::now() + Duration::from_secs(30);
        while core.inner.room(&room_id).is_err() {
            assert!(Instant::now() < deadline, "room never synced");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        let pid = std::process::id();
        let me = core.user_id();
        let body = format!("core round trip {pid} **bold** [me](https://matrix.to/#/{me})");
        core.send_text(room_id.clone(), body.clone(), vec![me.clone()], None).await.expect("send");
        let original = wait_for(&core, &room_id, deadline, move |e| {
            (e.content().as_message()?.body() == body).then(|| e.event_id().map(|id| id.to_string()))?
        })
        .await
        .expect("message never got an event ID from the server");

        // The server keeps the HTML and the mention.
        let inner = core.inner.clone();
        let (rid, id) = (room_id.clone(), original.clone());
        let stored = runtime::run(async move {
            let ev = inner.room(&rid).unwrap().event(&EventId::parse(&id).unwrap(), None).await.unwrap();
            serde_json::from_str::<serde_json::Value>(ev.raw().json().get()).unwrap()
        })
        .await;
        let content = &stored["content"];
        assert!(content["formatted_body"].as_str().unwrap_or("").contains("<strong>bold</strong>"), "{content}");
        assert_eq!(content["m.mentions"]["user_ids"][0].as_str(), Some(me.as_str()), "{content}");

        let reply = format!("core reply {pid}");
        core.send_reply(room_id.clone(), reply.clone(), original.clone(), vec![], None).await.expect("reply");
        let want = original.clone();
        wait_for(&core, &room_id, deadline, move |e| {
            let m = e.content().as_msglike()?;
            let replied = m.in_reply_to.as_ref()?.event_id.to_string();
            (m.as_message()?.body() == reply && replied == want && e.event_id().is_some()).then_some(())
        })
        .await
        .expect("reply never arrived pointing at the original");

        let edited = format!("core edited {pid}");
        core.edit_text(room_id.clone(), original.clone(), edited.clone()).await.expect("edit");
        let id = original.clone();
        wait_for(&core, &room_id, deadline, move |e| {
            let msg = e.content().as_message()?;
            (e.event_id()?.as_str() == id && msg.body() == edited && msg.is_edited()).then_some(())
        })
        .await
        .expect("edit never applied");

        // The timeline shows a redaction at once as a local echo, so ask the
        // server itself before signing out.
        core.redact(room_id.clone(), original.clone()).await.expect("unsend");
        let inner = core.inner.clone();
        let (rid, id) = (room_id.clone(), original.clone());
        let redacted = runtime::run(async move {
            let room = inner.room(&rid).unwrap();
            let event_id = EventId::parse(&id).unwrap();
            loop {
                if let Ok(ev) = room.event(&event_id, None).await {
                    if ev.raw().json().get().contains("redacted_because") {
                        return true;
                    }
                }
                if Instant::now() > deadline {
                    return false;
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
        })
        .await;
        assert!(redacted, "the server never redacted the message");

        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Against the live server: index every chat, find a new message, its
    /// edit and its unsend, search the server, and page the test room's media.
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... SB_TEST_ROOM=... cargo test -- --ignored live_search --nocapture
    #[tokio::test]
    #[ignore]
    async fn live_search_index() {
        use std::time::{Duration, Instant};

        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let room_id = std::env::var("SB_TEST_ROOM").expect("SB_TEST_ROOM");
        let dir = std::env::temp_dir().join(format!("sb-core-search-{}", std::process::id()));

        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        core.set_index_period(0).await.expect("period");
        let started = Instant::now();
        core.start_sync().await.expect("sync");

        // Wait for every chat to be indexed back to its start.
        let index = core.inner.index.clone();
        let deadline = Instant::now() + Duration::from_secs(300);
        let done = loop {
            let s = index.status_now();
            if s.chats > 0 && s.chats_done == s.chats && index.queued() == 0 {
                break s;
            }
            assert!(Instant::now() < deadline, "indexing never finished: {s:?}");
            tokio::time::sleep(Duration::from_millis(500)).await;
        };
        println!(
            "indexed {} messages in {} chats in {:.1}s, {} KB",
            done.messages,
            done.chats,
            started.elapsed().as_secs_f32(),
            done.bytes / 1000
        );

        let pid = std::process::id();
        let word = format!("zebrafish{pid}");
        core.send_text(room_id.clone(), format!("index probe {word}"), vec![], None).await.expect("send");
        let find = |q: String| {
            let core = &core;
            let room_id = room_id.clone();
            async move {
                let deadline = Instant::now() + Duration::from_secs(30);
                loop {
                    let hits = core.search_messages(q.clone(), Some(room_id.clone()), None, None, 0, 10).await.unwrap();
                    if !hits.is_empty() || Instant::now() > deadline {
                        return hits;
                    }
                    tokio::time::sleep(Duration::from_millis(300)).await;
                }
            }
        };
        let hits = find(word.clone()).await;
        assert_eq!(hits.len(), 1, "the new message was never indexed");
        let event_id = hits[0].message.event_id.clone();
        assert!(hits[0].snippet.contains(&format!("{}{word}{}", index::MARK_START, index::MARK_END)), "{:?}", hits[0]);
        assert!(hits[0].message.is_own);

        let edited = format!("edited{pid}");
        core.edit_text(room_id.clone(), event_id.clone(), format!("index probe {edited}")).await.expect("edit");
        let hits = find(edited.clone()).await;
        assert_eq!(hits.first().map(|h| h.message.event_id.clone()), Some(event_id.clone()), "edit never indexed");

        // The server's own index has it too, but the device's already does,
        // so the server's search leaves it out.
        let page = core.search_server(edited.clone(), Some(room_id.clone()), None, None, None).await.expect("server");
        assert!(page.hits.iter().all(|h| h.message.event_id != event_id), "{:?}", page.hits);

        let media = core.chat_media(room_id.clone(), MediaTab::Media, None, 50).await.expect("media");
        println!("test room: {} photos and videos on the first page, next {:?}", media.items.len(), media.next);

        core.redact(room_id.clone(), event_id.clone()).await.expect("unsend");
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let hits = core.search_messages(edited.clone(), None, None, None, 0, 10).await.unwrap();
            if hits.is_empty() {
                break;
            }
            assert!(Instant::now() < deadline, "the unsent message stayed in the index");
            tokio::time::sleep(Duration::from_millis(300)).await;
        }

        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Against the live server: send a photo, read it back and forward it,
    /// then send a voice note and a file.
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... SB_TEST_ROOM=... cargo test -- --ignored live_photo
    #[tokio::test]
    #[ignore]
    async fn live_photo_round_trip() {
        use std::time::{Duration, Instant};

        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let room_id = std::env::var("SB_TEST_ROOM").expect("SB_TEST_ROOM");
        let dir = std::env::temp_dir().join(format!("sb-core-photo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        let png = include_bytes!("../../tests/fixtures/red-2x2.png");
        let name = format!("core-photo-{}.png", std::process::id());
        let path = dir.join(&name);
        std::fs::write(&path, png).unwrap();

        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.join("store").to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        core.start_sync().await.expect("sync");
        let deadline = Instant::now() + Duration::from_secs(30);
        while core.inner.room(&room_id).is_err() {
            assert!(Instant::now() < deadline, "room never synced");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        core.send_file(room_id.clone(), path.to_string_lossy().into_owned(), "image/png".into(), Some(2), Some(2), None, false, None)
            .await
            .expect("send photo");
        let image_name = name.clone();
        let (event_id, mxc) = wait_for(&core, &room_id, deadline, move |e| {
            let id = e.event_id()?.to_string();
            let item = convert_event_for_test(e);
            match item.body {
                EventBody::Image { body, mxc: Some(mxc), width: Some(2), .. } if body == image_name => Some((id, mxc)),
                _ => None,
            }
        })
        .await
        .expect("photo never reached the server");

        let bytes = core.media(mxc.clone(), 0, 0).await.expect("download");
        assert_eq!(bytes, png.as_slice(), "downloaded photo differs");

        // Forwarding sends a second message with the same upload.
        core.forward(room_id.clone(), event_id.clone(), room_id.clone()).await.expect("forward");
        let original = mxc.clone();
        wait_for(&core, &room_id, deadline, move |e| {
            let id = e.event_id()?.to_string();
            match convert_event_for_test(e).body {
                EventBody::Image { body, mxc: Some(m), .. } if id != event_id && m == original && body == name => Some(()),
                _ => None,
            }
        })
        .await
        .expect("forwarded photo never arrived");

        // A voice note and a plain file keep their kind, name and size.
        let pid = std::process::id();
        let voice = dir.join(format!("voice-{pid}.wav"));
        std::fs::write(&voice, include_bytes!("../../tests/fixtures/beep.wav")).unwrap();
        core.send_file(room_id.clone(), voice.to_string_lossy().into_owned(), "audio/wav".into(), None, None, Some(500), true, None)
            .await
            .expect("send voice");
        let voice_name = format!("voice-{pid}.wav");
        wait_for(&core, &room_id, deadline, move |e| {
            e.event_id()?;
            match convert_event_for_test(e).body {
                EventBody::Audio { body, is_voice: true, duration_ms: Some(500), mxc: Some(_), .. } if body == voice_name => Some(()),
                _ => None,
            }
        })
        .await
        .expect("voice note never arrived as a voice note");

        let notes = dir.join(format!("notes-{pid}.txt"));
        std::fs::write(&notes, "hello").unwrap();
        core.send_file(room_id.clone(), notes.to_string_lossy().into_owned(), "text/plain".into(), None, None, None, false, None)
            .await
            .expect("send file");
        let notes_name = format!("notes-{pid}.txt");
        wait_for(&core, &room_id, deadline, move |e| {
            e.event_id()?;
            match convert_event_for_test(e).body {
                EventBody::File { name, size: Some(5), mimetype: Some(m), .. } if name == notes_name && m == "text/plain" => Some(()),
                _ => None,
            }
        })
        .await
        .expect("file never arrived");
        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Against the live server: Synapse previews a public page.
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... cargo test -- --ignored live_link_preview
    #[tokio::test]
    #[ignore]
    async fn live_link_preview() {
        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let dir = std::env::temp_dir().join(format!("sb-core-preview-{}", std::process::id()));
        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        let preview = core.link_preview("https://matrix.org/".into()).await;
        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
        let preview = preview.expect("preview request").expect("a preview with a title");
        assert!(preview.title.is_some(), "{preview:?}");
        println!("{preview:?}");
    }

    fn convert_event_for_test(e: &matrix_sdk_ui::timeline::EventTimelineItem) -> EventItem {
        match convert::timeline_item_kind_for_test(e) {
            TimelineItemKind::Event(item) => item,
            _ => unreachable!(),
        }
    }


    /// Against the live server: move the test room to Low Priority and
    /// back, checking the tag and the room's push rule each way.
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... SB_TEST_ROOM=... cargo test --lib -- --ignored live_low_priority
    #[tokio::test]
    #[ignore]
    async fn live_low_priority() {
        use matrix_sdk::notification_settings::RoomNotificationMode;
        use std::time::{Duration, Instant};

        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let room_id = std::env::var("SB_TEST_ROOM").expect("SB_TEST_ROOM");
        let dir = std::env::temp_dir().join(format!("sb-core-test-{}", std::process::id()));
        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        core.start_sync().await.expect("sync");
        let deadline = Instant::now() + Duration::from_secs(30);
        while core.inner.room(&room_id).is_err() {
            assert!(Instant::now() < deadline, "room never synced");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        // Each way: the tag arrives back through sync, and the push rule is
        // what the server now holds.
        for low in [true, false] {
            core.set_low_priority(vec![room_id.clone()], low).await.expect("set_low_priority");
            let inner = core.inner.clone();
            let rid = room_id.clone();
            let (tagged, mode) = runtime::run(async move {
                let room = inner.room(&rid).unwrap();
                let deadline = Instant::now() + Duration::from_secs(20);
                while room.is_low_priority() != low && Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
                let settings = inner.client.notification_settings().await;
                (room.is_low_priority(), settings.get_user_defined_room_notification_mode(room.room_id()).await)
            })
            .await;
            assert_eq!(tagged, low, "m.lowpriority tag");
            let want = if low { Some(RoomNotificationMode::MentionsAndKeywordsOnly) } else { None };
            assert_eq!(mode, want, "room push rule");
        }

        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// Against the live server: while the app isn't syncing (an iPhone app
    /// in the background), a message arrives and then a reaction to it.
    /// The next sync carries only the newest event per chat, so the chat
    /// list must still find the message and date the chat by it.
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... SB_TEST_ROOM=... cargo test --lib -- --ignored live_gap
    #[tokio::test]
    #[ignore]
    async fn live_gap_keeps_newest_message() {
        use matrix_sdk::ruma::{
            api::client::message::send_message_event::v3::Request as Send,
            events::{reaction::ReactionEventContent, relation::Annotation},
            TransactionId,
        };
        use std::time::{Duration, Instant};

        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let room_id = std::env::var("SB_TEST_ROOM").expect("SB_TEST_ROOM");
        let dir = std::env::temp_dir().join(format!("sb-core-gap-{}", std::process::id()));
        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        core.start_sync().await.expect("sync");
        let deadline = Instant::now() + Duration::from_secs(30);
        while core.inner.room(&room_id).is_err() {
            assert!(Instant::now() < deadline, "room never synced");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        // The chat list's view of the room, as the app gets it.
        let summary = {
            let inner = core.inner.clone();
            let rid = room_id.clone();
            move || {
                let inner = inner.clone();
                let rid = rid.clone();
                runtime::run(async move { inner.summary(inner.room(&rid).unwrap()).await })
            }
        };
        // A message while syncing, so the chat starts with a latest message
        // whatever earlier runs left.
        let before = format!("gap test before {}", std::process::id());
        let inner = core.inner.clone();
        let (rid, text) = (room_id.clone(), before.clone());
        runtime::run(async move {
            let message = RoomMessageEventContent::text_plain(text);
            inner.client.send(Send::new(RoomId::parse(&rid).unwrap(), TransactionId::new(), &message).unwrap()).await.unwrap();
        })
        .await;
        while summary().await.preview.map(|p| p.text) != Some(before.clone()) {
            assert!(Instant::now() < deadline, "the first message never became the latest");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        core.stop_sync().await.expect("stop sync");
        let body = format!("gap test {}", std::process::id());
        let inner = core.inner.clone();
        let (rid, text) = (room_id.clone(), body.clone());
        let (message_ts, reaction_id) = runtime::run(async move {
            let rid = RoomId::parse(&rid).unwrap();
            let message = RoomMessageEventContent::text_plain(text);
            let sent = inner.client.send(Send::new(rid.clone(), TransactionId::new(), &message).unwrap()).await.unwrap();
            let get = matrix_sdk::ruma::api::client::room::get_room_event::v3::Request::new(rid.clone(), sent.event_id.clone());
            let fetched = inner.client.send(get).await.unwrap();
            let ts = fetched.event.get_field::<i64>("origin_server_ts").unwrap().unwrap();
            let reaction = ReactionEventContent::new(Annotation::new(sent.event_id, "👍".into()));
            let reacted = inner.client.send(Send::new(rid, TransactionId::new(), &reaction).unwrap()).await.unwrap();
            (ts, reacted.event_id)
        })
        .await;

        core.start_sync().await.expect("restart sync");
        let inner = core.inner.clone();
        let rid = room_id.clone();
        runtime::run(async move {
            let room = inner.room(&rid).unwrap();
            let deadline = Instant::now() + Duration::from_secs(30);
            while !room_has_synced(&room, &reaction_id).await {
                assert!(Instant::now() < deadline, "the reaction never synced");
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        })
        .await;

        let deadline = Instant::now() + Duration::from_secs(20);
        let mut latest = summary().await;
        while latest.preview.as_ref().map(|p| p.text.as_str()) != Some(body.as_str()) && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(300)).await;
            latest = summary().await;
        }
        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(latest.preview.map(|p| p.text), Some(body), "the chat list missed the message");
        assert_eq!(latest.timestamp_ms, Some(message_ts), "the chat isn't dated by the message");
    }

    /// Whether the event came in through sync, so it's in the room's event
    /// cache rather than fetched from the server just now.
    async fn room_has_synced(room: &Room, event_id: &OwnedEventId) -> bool {
        let Ok((cache, _)) = room.event_cache().await else { return false };
        cache.find_event(event_id).await.ok().flatten().is_some()
    }

    /// Polls the room's timeline until `check` finds something.
    /// Replies sent into a thread stay out of the chat, show in the thread
    /// and are counted on the message that started it.
    ///   SB_TEST_USER=... SB_TEST_PASSWORD=... SB_TEST_ROOM=... cargo test --lib -- --ignored live_thread
    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn live_thread_round_trip() {
        use std::time::{Duration, Instant};

        let server = std::env::var("SB_TEST_SERVER")
            .unwrap_or_else(|_| "https://switchboard.example.ts.net".into());
        let user = std::env::var("SB_TEST_USER").expect("SB_TEST_USER");
        let password = std::env::var("SB_TEST_PASSWORD").expect("SB_TEST_PASSWORD");
        let room_id = std::env::var("SB_TEST_ROOM").expect("SB_TEST_ROOM");
        let dir = std::env::temp_dir().join(format!("sb-core-test-thread-{}", std::process::id()));

        let core = SwitchboardCore::login(
            server,
            user,
            password,
            "switchboard-core test".into(),
            dir.to_string_lossy().into_owned(),
            "test passphrase".into(),
        )
        .await
        .expect("login");
        core.start_sync().await.expect("sync");

        let deadline = Instant::now() + Duration::from_secs(30);
        while core.inner.room(&room_id).is_err() {
            assert!(Instant::now() < deadline, "room never synced");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        let pid = std::process::id();
        let body = format!("core thread start {pid}");
        core.send_text(room_id.clone(), body.clone(), vec![], None).await.expect("send");
        let root = wait_for(&core, &room_id, deadline, move |e| {
            (e.content().as_message()?.body() == body).then(|| e.event_id().map(|id| id.to_string()))?
        })
        .await
        .expect("message never got an event ID from the server");

        let replies = [format!("core thread reply one {pid}"), format!("core thread reply two {pid}")];
        for reply in &replies {
            core.send_text(room_id.clone(), reply.clone(), vec![], Some(root.clone())).await.expect("reply in thread");
        }

        // The thread has the message that started it and both replies, in
        // order, each pointing at the start.
        let inner = core.inner.clone();
        let (rid, id, want) = (room_id.clone(), root.clone(), replies.clone());
        let in_thread = runtime::run(async move {
            let thread = inner.thread_timeline(&rid, &id).await.unwrap();
            loop {
                let items: Vec<EventItem> =
                    thread.items().await.iter().filter_map(|i| i.as_event()).map(convert_event_for_test).collect();
                let sent: Vec<&EventItem> =
                    items.iter().filter(|e| e.event_id.is_some() && e.thread_root.as_deref() == Some(&id)).collect();
                let texts: Vec<String> = sent
                    .iter()
                    .filter_map(|e| match &e.body {
                        EventBody::Text { body, .. } => Some(body.clone()),
                        _ => None,
                    })
                    .collect();
                if texts == want {
                    return Ok(items.len());
                }
                if Instant::now() > deadline {
                    return Err(format!("{items:?}"));
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        })
        .await;
        in_thread.expect("the thread never held both replies");

        // The chat counts them on the message and shows neither.
        let (id, last) = (root.clone(), replies[1].clone());
        wait_for(&core, &room_id, deadline, move |e| {
            let shown = convert_event_for_test(e);
            let thread = shown.thread?;
            (e.event_id()?.as_str() == id && thread.reply_count == 2 && thread.latest_text.as_deref() == Some(&last))
                .then_some(())
        })
        .await
        .expect("the message never showed its two replies");
        let inner = core.inner.clone();
        let rid = room_id.clone();
        let in_chat = runtime::run(async move {
            let items = inner.timeline(&rid).await.unwrap().items().await;
            items.iter().filter_map(|i| i.as_event()).filter(|e| e.content().thread_root().is_some()).count()
        })
        .await;
        assert_eq!(in_chat, 0, "replies in a thread showed in the chat");

        core.logout().await.expect("logout");
        let _ = std::fs::remove_dir_all(&dir);
    }

    async fn wait_for<T: Send + 'static>(
        core: &SwitchboardCore,
        room_id: &str,
        deadline: std::time::Instant,
        check: impl Fn(&matrix_sdk_ui::timeline::EventTimelineItem) -> Option<T> + Send + 'static,
    ) -> Option<T> {
        let inner = core.inner.clone();
        let room_id = room_id.to_owned();
        runtime::run(async move {
            let timeline = inner.timeline(&room_id).await.ok()?;
            loop {
                let found = timeline.items().await.iter().filter_map(|i| i.as_event()).find_map(&check);
                if found.is_some() || std::time::Instant::now() > deadline {
                    return found;
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        })
        .await
    }
}
