//! RingRTC's call manager wired to Matrix. What RingRTC sends goes out as
//! call events in the DM portal, and the bridge's call events are read back
//! from the room and fed in. RingRTC's peer IDs are room IDs.
//!
//! The room list syncs only each room's latest event, so two call events in
//! one sync would lose the first. A call event in the sync is only a cue to
//! read the room's recent call events from the server.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, bail, Context, Result};
use matrix_sdk::{
    reqwest,
    room::MessagesOptions,
    ruma::{events::AnySyncTimelineEvent, serde::Raw, uint, OwnedEventId, OwnedRoomId, OwnedUserId, RoomId},
    Client, Room,
};
use ringrtc::{
    common::{CallConfig, CallEndReason, CallId, CallMediaType, DeviceId},
    core::{call_manager::CallManager, group_call, signaling},
    lite::{http, sfu::UserId},
    native::{
        CallState, CallStateHandler, GroupUpdate, GroupUpdateHandler, NativeCallContext, NativePlatform,
        SignalingSender,
    },
    webrtc::{
        media::{AudioTrack, VideoSource, VideoTrack},
        peer_connection::AudioLevel,
        peer_connection_factory::{
            AudioConfig, AudioDevice, AudioDeviceList, DefaultAudioDevice, IceServer, PeerConnectionFactory,
        },
        peer_connection_observer::NetworkRoute,
    },
};
use serde::Deserialize;
use tokio::sync::mpsc;

use super::{
    camera::Camera,
    content::{self, Content, Received},
    video::{self, FrameSlot},
    EVENT_TYPE,
};
use crate::{
    api::calls::{CallFrame, CallPhase, CallUpdate},
    frb_generated::StreamSink,
};

/// Call events older than this are history, not signalling. RingRTC drops
/// offers after a minute anyway.
const MAX_EVENT_AGE: Duration = Duration::from_secs(120);
/// How long to reuse the bridge's device ID and TURN servers.
const CONFIG_TTL: Duration = Duration::from_secs(300);
/// The Signal bridge's catalogue ID, for its provisioning API via the Hub.
const BRIDGE: &str = "signal";
/// Width, height and frame rate.
const MAX_VIDEO: (u16, u16, u8) = (960, 720, 30);

pub(crate) struct CallService {
    client: Client,
    homeserver_url: String,
    http: reqwest::Client,
    manager: StdMutex<CallManager<NativePlatform>>,
    /// The same factory RingRTC has, for picking audio devices.
    factory: StdMutex<PeerConnectionFactory>,
    audio_track: AudioTrack,
    /// Off until the camera is on and the call connected. The camera pushes
    /// frames into the source.
    video_track: VideoTrack,
    video_source: VideoSource,
    camera: StdMutex<Option<Camera>>,
    /// The contact's newest frame, and the camera's for the preview.
    remote_frames: FrameSlot,
    local_frames: FrameSlot,
    updates: StdMutex<Option<StreamSink<CallUpdate>>>,
    listening: AtomicBool,
    active: StdMutex<Option<ActiveCall>>,
    /// How to say a call ended that another Switchboard client took.
    ended_elsewhere: StdMutex<Option<(CallId, CallEndReason)>>,
    seen: StdMutex<Seen>,
    /// Rooms being read, and whether another read was asked for meanwhile.
    reading: StdMutex<HashMap<OwnedRoomId, bool>>,
    config: StdMutex<Option<(Instant, CallsConfig)>>,
}

struct ActiveCall {
    room_id: String,
    call_id: CallId,
    incoming: bool,
    /// Placed as a video call.
    offered_video: bool,
    phase: CallPhase,
    muted: bool,
    /// Our camera is on, or will be once connected.
    video: bool,
    remote_video: bool,
    /// Answer was pressed here. Only then does an incoming call proceed, and
    /// it's accepted once RingRTC rings: it drops an accept before that.
    answered: bool,
}

// What RingRTC's callbacks hand over. They run on RingRTC's thread and
// mustn't block, so tasks work through these in order. States have their own
// queue so a ring isn't held up behind sends.

struct Outgoing {
    room_id: String,
    call_id: CallId,
    destination: Option<DeviceId>,
    message: signaling::Message,
}

enum StateChange {
    Call { room_id: String, call_id: CallId, state: Box<CallState> },
    RemoteVideo { room_id: String, enabled: bool },
}

impl CallService {
    /// Sets up RingRTC. Runs on the core's runtime.
    pub(crate) fn start(client: Client, homeserver_url: String) -> Result<Arc<Self>> {
        ringrtc::webrtc::logging::set_logger(log::LevelFilter::Warn);
        let factory = PeerConnectionFactory::new(&AudioConfig::default(), false, "", None)?;
        let audio_track = factory.create_outgoing_audio_track()?;
        audio_track.set_enabled(false);
        let video_source = factory.create_outgoing_video_source()?;
        let video_track = factory.create_outgoing_video_track(&video_source)?;
        video_track.set_enabled(false);

        let (outgoing, sends) = mpsc::unbounded_channel();
        let (state_changes, states) = mpsc::unbounded_channel();
        let platform = NativePlatform::new(
            factory.clone(),
            Box::new(Signaling(outgoing)),
            // RingRTC waits for `message_sent` after each send, so ICE
            // candidates found meanwhile go out in one event.
            false,
            Box::new(States(state_changes)),
            Box::new(NoGroupCalls),
        );
        let manager = CallManager::new(platform, http::DelegatingClient::new(NoHttp))?;
        let service = Arc::new(CallService {
            client: client.clone(),
            homeserver_url,
            http: reqwest::Client::new(),
            manager: StdMutex::new(manager),
            factory: StdMutex::new(factory),
            audio_track,
            video_track,
            video_source,
            camera: StdMutex::new(None),
            remote_frames: FrameSlot::default(),
            local_frames: FrameSlot::default(),
            updates: StdMutex::new(None),
            listening: AtomicBool::new(false),
            active: StdMutex::new(None),
            ended_elsewhere: StdMutex::new(None),
            seen: StdMutex::new(Seen::default()),
            reading: StdMutex::new(HashMap::new()),
            config: StdMutex::new(None),
        });
        tokio::spawn(service.clone().send_all(sends));
        tokio::spawn(service.clone().handle_states(states));
        Ok(service)
    }

    /// Sends call updates to `updates`, replacing any earlier listener, and
    /// starts taking calls the first time.
    pub(crate) fn subscribe(self: &Arc<Self>, updates: StreamSink<CallUpdate>) {
        *self.updates.lock().unwrap() = Some(updates);
        if self.listening.swap(true, Ordering::SeqCst) {
            return;
        }
        let weak = Arc::downgrade(self);
        self.client.add_event_handler(move |event: Raw<AnySyncTimelineEvent>, room: Room| {
            let weak = weak.clone();
            async move {
                if let Some(service) = weak.upgrade() {
                    service.on_sync_event(&event, room);
                }
            }
        });
    }

    pub(crate) async fn place_call(&self, room_id: &str, video: bool) -> Result<()> {
        let room_id = RoomId::parse(room_id)?;
        self.client.get_room(&room_id).ok_or_else(|| anyhow!("unknown room {room_id}"))?;
        if self.active.lock().unwrap().is_some() {
            bail!("already in a call");
        }
        let config = self.config().await.context("can't reach the Signal bridge")?;
        // The preview shows while it rings.
        if video {
            self.start_camera()?;
        }
        let media = if video { CallMediaType::Video } else { CallMediaType::Audio };
        self.manager.lock().unwrap().call(room_id.to_string(), media, config.device_id);
        Ok(())
    }

    pub(crate) fn accept(self: &Arc<Self>, call_id: &str, video: bool) -> Result<()> {
        let call_id = CallId::new(call_id.parse()?);
        let ringing = |c: &ActiveCall| c.call_id == call_id && c.incoming && c.phase != CallPhase::Connected;
        if !self.active.lock().unwrap().as_ref().is_some_and(ringing) {
            bail!("that call isn't ringing");
        }
        // Not under the lock: the camera's first frame can take a moment.
        if video {
            self.start_camera()?;
        }
        let mut active = self.active.lock().unwrap();
        let Some(call) = active.as_mut().filter(|c| ringing(c)) else {
            drop(active);
            self.stop_camera();
            bail!("that call isn't ringing");
        };
        call.video = video;
        if !call.answered {
            call.answered = true;
            let service = self.clone();
            tokio::spawn(async move { service.proceed(call_id).await });
        }
        Ok(())
    }

    /// Ends the active call, or declines it while it rings.
    pub(crate) fn hang_up(&self) {
        self.manager.lock().unwrap().hangup();
    }

    pub(crate) fn set_muted(&self, muted: bool) -> Result<()> {
        let mut active = self.active.lock().unwrap();
        let call = active.as_mut().ok_or_else(|| anyhow!("not in a call"))?;
        call.muted = muted;
        if call.phase == CallPhase::Connected {
            self.set_audio(!muted);
        }
        Ok(())
    }

    fn set_audio(&self, enabled: bool) {
        self.audio_track.set_enabled(enabled);
        // Tells the contact's app, which shows them as muted.
        if let Ok(mut connection) = self.manager.lock().unwrap().active_connection()
            && let Err(e) = connection
                .update_sender_status(signaling::SenderStatus { audio_enabled: Some(enabled), ..Default::default() })
        {
            tracing::warn!("call mute status: {e:#}");
        }
    }

    pub(crate) fn set_video(&self, enabled: bool) -> Result<()> {
        if self.active.lock().unwrap().is_none() {
            bail!("not in a call");
        }
        if enabled {
            self.start_camera()?;
        } else {
            self.stop_camera();
        }
        let mut active = self.active.lock().unwrap();
        let call = active.as_mut().ok_or_else(|| anyhow!("not in a call"))?;
        call.video = enabled;
        if call.phase == CallPhase::Connected {
            self.send_video(enabled);
        }
        Ok(())
    }

    fn send_video(&self, enabled: bool) {
        self.video_track.set_enabled(enabled);
        // Tells the contact's app, which shows our avatar instead.
        if let Ok(mut connection) = self.manager.lock().unwrap().active_connection()
            && let Err(e) = connection
                .update_sender_status(signaling::SenderStatus { video_enabled: Some(enabled), ..Default::default() })
        {
            tracing::warn!("call video status: {e:#}");
        }
    }

    fn start_camera(&self) -> Result<()> {
        let mut camera = self.camera.lock().unwrap();
        if camera.is_none() {
            *camera = Some(Camera::start(self.video_source.clone(), self.local_frames.clone())?);
        }
        Ok(())
    }

    fn stop_camera(&self) {
        // Dropping it waits for its thread, so no frame lands after the clear.
        self.camera.lock().unwrap().take();
        self.local_frames.clear();
    }

    pub(crate) fn remote_frame(&self, max_width: u32, max_height: u32) -> Option<CallFrame> {
        video::to_rgba(self.remote_frames.take()?, max_width, max_height)
    }

    pub(crate) fn local_frame(&self, max_width: u32, max_height: u32) -> Option<CallFrame> {
        video::to_rgba(self.local_frames.take()?, max_width, max_height)
    }

    fn on_sync_event(self: &Arc<Self>, event: &Raw<AnySyncTimelineEvent>, room: Room) {
        if event.get_field::<OwnedUserId>("sender").ok().flatten().as_deref() == self.client.user_id() {
            return;
        }
        let is_call_event = event.get_field::<String>("type").ok().flatten().as_deref() == Some(EVENT_TYPE);
        // A call event can hide behind a later message in the same sync.
        let in_call = self.active.lock().unwrap().as_ref().is_some_and(|c| c.room_id == room.room_id().as_str());
        if is_call_event || in_call {
            tokio::spawn(self.clone().read_room(room));
        }
    }

    /// Reads `room`'s call events, once more if asked again meanwhile.
    async fn read_room(self: Arc<Self>, room: Room) {
        let room_id = room.room_id().to_owned();
        {
            let mut reading = self.reading.lock().unwrap();
            if let Some(again) = reading.get_mut(&room_id) {
                *again = true;
                return;
            }
            reading.insert(room_id.clone(), false);
        }
        loop {
            if let Err(e) = self.read_call_events(&room).await {
                tracing::warn!("reading call events in {room_id}: {e:#}");
            }
            let mut reading = self.reading.lock().unwrap();
            if reading.get(&room_id) == Some(&true) {
                reading.insert(room_id.clone(), false);
            } else {
                reading.remove(&room_id);
                return;
            }
        }
    }

    async fn read_call_events(&self, room: &Room) -> Result<()> {
        let mut options = MessagesOptions::backward();
        options.limit = uint!(50);
        options.filter.types = Some(vec![EVENT_TYPE.to_owned()]);
        let messages = room.messages(options).await?;
        let own = self.client.user_id().map(ToOwned::to_owned);
        let now = now_ms();
        // Newest first from the server; RingRTC needs them in order.
        for event in messages.chunk.iter().rev() {
            let raw = event.raw();
            let Some(event_id) = raw.get_field::<OwnedEventId>("event_id")? else {
                continue;
            };
            let sent_ms = raw.get_field::<u64>("origin_server_ts")?.unwrap_or(0);
            if now.saturating_sub(sent_ms) > MAX_EVENT_AGE.as_millis() as u64
                || raw.get_field::<OwnedUserId>("sender")? == own
                || !self.seen.lock().unwrap().insert(event_id.clone())
            {
                continue;
            }
            let fed = raw
                .get_field::<Content>("content")
                .map_err(anyhow::Error::from)
                .and_then(|content| content.ok_or_else(|| anyhow!("no content")))
                .and_then(|content| self.feed(room.room_id(), content, now, sent_ms));
            if let Err(e) = fed {
                tracing::warn!("call event {event_id}: {e:#}");
            }
        }
        Ok(())
    }

    fn feed(&self, room_id: &RoomId, content: Content, now_ms: u64, sent_ms: u64) -> Result<()> {
        if let Some(received) = content::received(content, now_ms, sent_ms)? {
            if let Received::Offer(call_id, offer) = &received {
                tracing::debug!(
                    "call offer {}: {} ms since Signal took it, {} ms since the bridge posted it",
                    call_id.as_u64(),
                    offer.age.as_millis(),
                    now_ms.saturating_sub(sent_ms),
                );
            }
            if let Received::Hangup(call_id, hangup) = &received
                && let Some(reason) = self.taken_elsewhere(*call_id, &hangup.hangup)
            {
                tracing::debug!("call {} taken by another Switchboard client: {reason:?}", call_id.as_u64());
                *self.ended_elsewhere.lock().unwrap() = Some((*call_id, reason));
                self.manager.lock().unwrap().drop_call(*call_id);
                return Ok(());
            }
            deliver(&mut self.manager.lock().unwrap(), room_id.to_string(), received);
        }
        Ok(())
    }

    /// Every Switchboard client is the bridge's one Signal device, so when
    /// one answers or declines, the caller tells the rest it happened on
    /// their own device, which RingRTC ignores. Gives how to end the call if
    /// `hangup` is that, for a call this client didn't answer.
    fn taken_elsewhere(&self, call_id: CallId, hangup: &signaling::Hangup) -> Option<CallEndReason> {
        let device_id = self.config.lock().unwrap().as_ref().map(|(_, config)| config.device_id)?;
        let reason = on_device(hangup, device_id)?;
        let ours = self.active.lock().unwrap().as_ref().is_some_and(|c| c.call_id == call_id && (!c.incoming || c.answered));
        (!ours).then_some(reason)
    }

    async fn send_all(self: Arc<Self>, mut queue: mpsc::UnboundedReceiver<Outgoing>) {
        while let Some(Outgoing { room_id, call_id, destination, message }) = queue.recv().await {
            let content = content::from_message(call_id, destination, message);
            let started = Instant::now();
            let sent = self.send(&room_id, &content).await;
            tracing::debug!(
                "call {:?} with {} candidates sent in {} ms",
                content.kind,
                content.candidates.len(),
                started.elapsed().as_millis(),
            );
            let mut manager = self.manager.lock().unwrap();
            match sent {
                Ok(()) => manager.message_sent(call_id),
                Err(e) => {
                    tracing::warn!("sending call {:?} to {room_id}: {e:#}", content.kind);
                    manager.message_send_failure(call_id);
                }
            }
        }
    }

    async fn handle_states(self: Arc<Self>, mut queue: mpsc::UnboundedReceiver<StateChange>) {
        while let Some(change) = queue.recv().await {
            match change {
                StateChange::Call { room_id, call_id, state } => self.on_state(room_id, call_id, *state).await,
                StateChange::RemoteVideo { room_id, enabled } => self.on_remote_video(&room_id, enabled),
            }
        }
    }

    async fn send(&self, room_id: &str, content: &Content) -> Result<()> {
        let room_id = RoomId::parse(room_id)?;
        let room = self.client.get_room(&room_id).ok_or_else(|| anyhow!("unknown room"))?;
        room.send_raw(EVENT_TYPE, serde_json::to_value(content)?).await?;
        Ok(())
    }

    async fn on_state(&self, room_id: String, call_id: CallId, state: CallState) {
        let emit = |phase, reason| self.emit(&room_id, call_id, phase, reason);
        let incoming = matches!(state, CallState::Incoming(_));
        match state {
            CallState::Incoming(media) | CallState::Outgoing(media) => {
                let phase = if incoming { CallPhase::Incoming } else { CallPhase::Outgoing };
                let offered_video = media == CallMediaType::Video;
                *self.active.lock().unwrap() = Some(ActiveCall {
                    room_id: room_id.clone(),
                    call_id,
                    incoming,
                    offered_video,
                    phase,
                    muted: false,
                    // Placing a video call started the camera.
                    video: !incoming && offered_video,
                    remote_video: false,
                    answered: false,
                });
                emit(phase, None);
                if incoming {
                    // Proceeding sends our answer, and the caller connects to
                    // the first one, so only the client answered on does. The
                    // bridge's settings are fetched now so that's quick.
                    let _ = self.config().await;
                } else {
                    self.proceed(call_id).await;
                }
            }
            CallState::Ringing => {
                let accept = self.set_phase(call_id, CallPhase::Ringing).is_some_and(|c| c.answered);
                emit(CallPhase::Ringing, None);
                if accept {
                    self.manager.lock().unwrap().accept_call(call_id);
                }
            }
            CallState::Connecting => {
                self.set_phase(call_id, CallPhase::Connecting);
                emit(CallPhase::Connecting, None);
            }
            CallState::Connected => {
                if let Some(call) = self.set_phase(call_id, CallPhase::Connected) {
                    self.set_audio(!call.muted);
                    self.send_video(call.video);
                }
                emit(CallPhase::Connected, None);
            }
            CallState::Ended(reason, _) => {
                let reason = match self.ended_elsewhere.lock().unwrap().take() {
                    Some((dropped, elsewhere)) if dropped == call_id => elsewhere,
                    _ => reason,
                };
                if self.set_phase(call_id, CallPhase::Ended).is_some() {
                    self.audio_track.set_enabled(false);
                    self.video_track.set_enabled(false);
                    self.stop_camera();
                    self.remote_frames.clear();
                }
                emit(CallPhase::Ended, Some(format!("{reason:?}")));
            }
            // An offer RingRTC turned away, such as one over a minute old.
            CallState::Rejected(reason) => emit(CallPhase::Ended, Some(format!("{reason:?}"))),
            CallState::Concluded => {
                let mut active = self.active.lock().unwrap();
                if active.as_ref().is_some_and(|c| c.call_id == call_id) {
                    *active = None;
                }
            }
        }
    }

    fn on_remote_video(&self, room_id: &str, enabled: bool) {
        let call = {
            let mut active = self.active.lock().unwrap();
            let Some(call) = active.as_mut().filter(|c| c.room_id == room_id) else {
                return;
            };
            call.remote_video = enabled;
            (call.call_id, call.phase)
        };
        if !enabled {
            self.remote_frames.clear();
        }
        self.emit(room_id, call.0, call.1, None);
    }

    /// Tells the app where `call_id` is up to.
    fn emit(&self, room_id: &str, call_id: CallId, phase: CallPhase, reason: Option<String>) {
        let (video, remote_video) = self
            .active
            .lock()
            .unwrap()
            .as_ref()
            .filter(|c| c.call_id == call_id)
            .map_or((false, false), |c| (c.offered_video, c.remote_video));
        if let Some(updates) = self.updates.lock().unwrap().as_ref() {
            let _ = updates.add(CallUpdate {
                room_id: room_id.to_owned(),
                call_id: call_id.as_u64().to_string(),
                phase,
                video,
                remote_video,
                reason,
            });
        }
    }

    /// Moves the active call on, if it's `call_id`. Returns what it knew.
    fn set_phase(&self, call_id: CallId, phase: CallPhase) -> Option<ActiveSnapshot> {
        let mut active = self.active.lock().unwrap();
        let call = active.as_mut().filter(|c| c.call_id == call_id)?;
        call.phase = phase;
        Some(ActiveSnapshot { muted: call.muted, video: call.video, answered: call.answered })
    }

    async fn proceed(&self, call_id: CallId) {
        let ice_servers = match self.config().await {
            Ok(config) => config.ice_servers().into_iter().map(IceSpec::into_server).collect(),
            Err(e) => {
                // Without TURN only a direct route can work, but it's worth a try.
                tracing::warn!("no TURN servers for the call: {e:#}");
                Vec::new()
            }
        };
        self.use_default_audio_devices();
        // As Signal Desktop: camera video, no bigger than 960x720 at 30 fps.
        self.video_track.set_content_hint(false);
        self.video_source.adapt_output_format(MAX_VIDEO.0, MAX_VIDEO.1, MAX_VIDEO.2);
        let context = NativeCallContext::new(
            false,
            ice_servers,
            self.audio_track.clone(),
            self.video_track.clone(),
            Box::new(self.remote_frames.clone()),
        );
        self.manager.lock().unwrap().proceed(call_id, context, CallConfig::default(), None);
    }

    /// Points RingRTC at the system's default speaker and microphone, read
    /// afresh for each call. It opens only devices the app has picked and
    /// picks none itself, so without this a call connects in silence.
    fn use_default_audio_devices(&self) {
        let mut factory = self.factory.lock().unwrap();
        let speakers = factory.get_audio_playout_devices();
        pick_device("speaker", speakers, |id| factory.set_audio_playout_device_by_id(id, 0));
        let microphones = factory.get_audio_recording_devices();
        pick_device("microphone", microphones, |id| factory.set_audio_recording_device_by_id(id, 0));
    }

    /// The bridge's Signal device ID and Signal's TURN servers.
    async fn config(&self) -> Result<CallsConfig> {
        if let Some((fetched, config)) = self.config.lock().unwrap().as_ref()
            && fetched.elapsed() < CONFIG_TTL
        {
            return Ok(config.clone());
        }
        let token = self.client.access_token().ok_or_else(|| anyhow!("not signed in"))?;
        let url = format!("{}/_switchboard/v1/bridges/{BRIDGE}/provision/v3/calls/config", self.homeserver_url);
        let body = self.http.get(url).bearer_auth(token).send().await?.error_for_status()?.text().await?;
        let config: CallsConfig = serde_json::from_str(&body)?;
        *self.config.lock().unwrap() = Some((Instant::now(), config.clone()));
        Ok(config)
    }
}

struct ActiveSnapshot {
    muted: bool,
    video: bool,
    answered: bool,
}

/// `GET /v3/calls/config` on the Signal bridge.
#[derive(Clone, Debug, Deserialize)]
struct CallsConfig {
    device_id: DeviceId,
    relays: Option<Vec<Relay>>,
}

/// One entry of Signal's `GET /v2/calling/relays`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Relay {
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    urls: Vec<String>,
    #[serde(default)]
    urls_with_ips: Vec<String>,
    #[serde(default)]
    hostname: String,
}

#[derive(Debug, PartialEq)]
struct IceSpec {
    username: String,
    password: String,
    hostname: String,
    urls: Vec<String>,
}

impl IceSpec {
    fn into_server(self) -> IceServer {
        IceServer::new(self.username, self.password, self.hostname, self.urls)
    }
}

impl CallsConfig {
    /// As Signal Desktop does: the IP URLs first, with the hostname for TLS,
    /// then the named ones.
    fn ice_servers(&self) -> Vec<IceSpec> {
        let mut servers = Vec::new();
        for relay in self.relays.iter().flatten() {
            for (hostname, urls) in [(&relay.hostname, &relay.urls_with_ips), (&String::new(), &relay.urls)] {
                if !urls.is_empty() {
                    servers.push(IceSpec {
                        username: relay.username.clone(),
                        password: relay.password.clone(),
                        hostname: hostname.clone(),
                        urls: urls.clone(),
                    });
                }
            }
        }
        servers
    }
}

/// Event IDs already fed to RingRTC, the newest thousand.
#[derive(Default)]
struct Seen {
    order: VecDeque<OwnedEventId>,
    ids: HashSet<OwnedEventId>,
}

impl Seen {
    const CAP: usize = 1000;

    /// False if `id` was seen before.
    fn insert(&mut self, id: OwnedEventId) -> bool {
        if !self.ids.insert(id.clone()) {
            return false;
        }
        self.order.push_back(id);
        if self.order.len() > Self::CAP
            && let Some(old) = self.order.pop_front()
        {
            self.ids.remove(&old);
        }
        true
    }
}

fn pick_device(kind: &str, devices: Result<AudioDeviceList>, set: impl FnOnce(&str) -> Result<()>) {
    let picked = devices.and_then(|devices| {
        let device = default_device(&devices).ok_or_else(|| anyhow!("none found"))?;
        tracing::debug!("call {kind}: {}", device.name);
        set(&device.unique_id)
    });
    if let Err(e) = picked {
        tracing::warn!("call {kind}: {e:#}");
    }
}

/// The device the system prefers for voice, else the first one.
fn default_device(devices: &AudioDeviceList) -> Option<&AudioDevice> {
    match &devices.default {
        DefaultAudioDevice::NonWindows(Some(device)) => Some(device),
        _ => devices.list.first(),
    }
}

/// The end reason for a hangup saying `device_id` took the call.
fn on_device(hangup: &signaling::Hangup, device_id: DeviceId) -> Option<CallEndReason> {
    match *hangup {
        signaling::Hangup::AcceptedOnAnotherDevice(d) if d == device_id => Some(CallEndReason::RemoteHangupAccepted),
        signaling::Hangup::DeclinedOnAnotherDevice(d) if d == device_id => Some(CallEndReason::RemoteHangupDeclined),
        signaling::Hangup::BusyOnAnotherDevice(d) if d == device_id => Some(CallEndReason::RemoteHangupBusy),
        _ => None,
    }
}

/// Hands a message from `peer` to RingRTC.
pub(super) fn deliver(manager: &mut CallManager<NativePlatform>, peer: String, received: Received) {
    match received {
        Received::Offer(call_id, offer) => manager.received_offer(peer, call_id, offer),
        Received::Answer(call_id, answer) => manager.received_answer(peer, call_id, answer),
        Received::Ice(call_id, ice) => manager.received_ice(peer, call_id, ice),
        Received::Hangup(call_id, hangup) => manager.received_hangup(peer, call_id, hangup),
        Received::Busy(call_id, busy) => manager.received_busy(peer, call_id, busy),
    }
}

pub(super) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

struct Signaling(mpsc::UnboundedSender<Outgoing>);

impl SignalingSender for Signaling {
    fn send_signaling(
        &self,
        recipient_id: &str,
        call_id: CallId,
        receiver_device_id: Option<DeviceId>,
        message: signaling::Message,
    ) -> Result<()> {
        let _ = self.0.send(Outgoing {
            room_id: recipient_id.to_owned(),
            call_id,
            destination: receiver_device_id,
            message,
        });
        Ok(())
    }

    // The rest are for group calls.

    fn send_call_message(&self, _: UserId, _: Vec<u8>, _: group_call::SignalingMessageUrgency) -> Result<()> {
        Ok(())
    }

    fn send_call_message_to_group(
        &self,
        _: group_call::GroupId,
        _: Vec<u8>,
        _: group_call::SignalingMessageUrgency,
        _: HashSet<UserId>,
    ) -> Result<()> {
        Ok(())
    }

    fn send_call_message_to_adhoc_group(
        &self,
        _: Vec<u8>,
        _: group_call::SignalingMessageUrgency,
        _: u64,
        _: HashMap<UserId, Vec<u8>>,
    ) -> Result<()> {
        Ok(())
    }
}

struct States(mpsc::UnboundedSender<StateChange>);

impl CallStateHandler for States {
    fn handle_call_state(&self, remote_peer_id: &str, call_id: CallId, state: CallState) -> Result<()> {
        let _ = self.0.send(StateChange::Call { room_id: remote_peer_id.to_owned(), call_id, state: Box::new(state) });
        Ok(())
    }

    fn handle_remote_audio_state(&self, _: &str, _: bool) -> Result<()> {
        Ok(())
    }

    fn handle_remote_video_state(&self, remote_peer_id: &str, enabled: bool) -> Result<()> {
        let _ = self.0.send(StateChange::RemoteVideo { room_id: remote_peer_id.to_owned(), enabled });
        Ok(())
    }

    fn handle_remote_sharing_screen(&self, _: &str, _: bool) -> Result<()> {
        Ok(())
    }

    fn handle_network_route(&self, _: &str, _: NetworkRoute) -> Result<()> {
        Ok(())
    }

    fn handle_audio_levels(&self, _: &str, _: AudioLevel, _: AudioLevel) -> Result<()> {
        Ok(())
    }

    fn handle_low_bandwidth_for_video(&self, _: &str, _: bool) -> Result<()> {
        Ok(())
    }
}

pub(super) struct NoGroupCalls;

impl GroupUpdateHandler for NoGroupCalls {
    fn handle_group_update(&self, _: GroupUpdate) -> Result<()> {
        Ok(())
    }
}

/// Only group calls make HTTP requests.
pub(super) struct NoHttp;

impl http::Delegate for NoHttp {
    fn send_request(&self, _: u32, _: http::Request) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::owned_event_id;

    #[test]
    fn ice_servers_put_ip_urls_first() {
        let config: CallsConfig = serde_json::from_str(
            r#"{"device_id": 2, "relays": [{
                "username": "u", "password": "p", "hostname": "turn.example",
                "urls": ["turn:turn.example"], "urlsWithIps": ["turn:192.0.2.1"], "ttl": 86400
            }]}"#,
        )
        .unwrap();
        assert_eq!(config.device_id, 2);
        let spec = |hostname: &str, url: &str| IceSpec {
            username: "u".into(),
            password: "p".into(),
            hostname: hostname.into(),
            urls: vec![url.into()],
        };
        assert_eq!(
            config.ice_servers(),
            vec![spec("turn.example", "turn:192.0.2.1"), spec("", "turn:turn.example")]
        );
    }

    #[test]
    fn no_relays_means_no_ice_servers() {
        let config: CallsConfig = serde_json::from_str(r#"{"device_id": 2, "relays": null}"#).unwrap();
        assert!(config.ice_servers().is_empty());
    }

    #[test]
    fn calls_use_the_voice_default_device() {
        let device = |name: &str| AudioDevice { name: name.into(), unique_id: format!("{name}-id") };
        let mut devices = AudioDeviceList::new_with_default(DefaultAudioDevice::NonWindows(Some(device("Headphones"))));
        devices.list = vec![device("Speaker"), device("Headphones")];
        assert_eq!(default_device(&devices).map(|d| d.name.as_str()), Some("Headphones"));
        devices.default = DefaultAudioDevice::NonWindows(None);
        assert_eq!(default_device(&devices).map(|d| d.name.as_str()), Some("Speaker"));
    }

    #[test]
    fn hangups_naming_our_device_say_how_it_ended() {
        use signaling::Hangup;
        assert_eq!(on_device(&Hangup::AcceptedOnAnotherDevice(3), 3), Some(CallEndReason::RemoteHangupAccepted));
        assert_eq!(on_device(&Hangup::DeclinedOnAnotherDevice(3), 3), Some(CallEndReason::RemoteHangupDeclined));
        assert_eq!(on_device(&Hangup::BusyOnAnotherDevice(3), 3), Some(CallEndReason::RemoteHangupBusy));
        // RingRTC ends calls taken on the contact's other devices itself.
        assert_eq!(on_device(&Hangup::AcceptedOnAnotherDevice(2), 3), None);
        assert_eq!(on_device(&Hangup::Normal, 3), None);
    }

    #[test]
    fn seen_forgets_the_oldest() {
        let mut seen = Seen::default();
        assert!(seen.insert(owned_event_id!("$first")));
        assert!(!seen.insert(owned_event_id!("$first")));
        for i in 0..Seen::CAP {
            seen.insert(OwnedEventId::try_from(format!("${i}")).unwrap());
        }
        assert!(seen.insert(owned_event_id!("$first")));
    }
}
