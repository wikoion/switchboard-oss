//! Signal calls where RingRTC runs in the app rather than here: on iOS,
//! Signal's Swift package does (`app/ios/Runner/CallsBridge.swift`). The
//! core only carries the call events between the DM portal and the app, and
//! fetches the bridge's call settings.
//!
//! Reading follows the Linux service (`service.rs`): the room list syncs
//! only each room's latest event, so a call event in the sync is a cue to
//! read the room's recent call events from the server.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, bail, Result};
use matrix_sdk::{
    reqwest,
    room::MessagesOptions,
    ruma::{events::AnySyncTimelineEvent, serde::Raw, uint, OwnedEventId, OwnedRoomId, OwnedUserId, RoomId},
    Client, Room,
};
use serde::Deserialize;

use super::{
    content::{Content, DeviceId, Kind},
    EVENT_TYPE,
};
use crate::{
    api::calls::{CallFrame, CallSettings, CallSignal, CallSignalKind, CallUpdate, IceServerSpec},
    frb_generated::StreamSink,
};

/// Call events older than this are history, not signalling. RingRTC drops
/// offers after a minute anyway.
const MAX_EVENT_AGE: Duration = Duration::from_secs(120);
/// How long to reuse the bridge's device ID and TURN servers.
const CONFIG_TTL: Duration = Duration::from_secs(300);
/// The Signal bridge's catalogue ID, for its provisioning API via the Hub.
const BRIDGE: &str = "signal";
const ELSEWHERE: &str = "this platform runs calls in the app, not the core";

pub(crate) struct CallService {
    client: Client,
    homeserver_url: String,
    http: reqwest::Client,
    signals: StdMutex<Option<StreamSink<CallSignal>>>,
    listening: AtomicBool,
    /// The chat of the call in progress: any event there is read for call
    /// events, which can hide behind a message in the same sync.
    call_room: StdMutex<Option<OwnedRoomId>>,
    seen: StdMutex<Seen>,
    /// Rooms being read, and whether another read was asked for meanwhile.
    reading: StdMutex<HashMap<OwnedRoomId, bool>>,
    config: StdMutex<Option<(Instant, CallsConfig)>>,
}

impl CallService {
    pub(crate) fn start(client: Client, homeserver_url: String) -> Result<Arc<Self>> {
        Ok(Arc::new(CallService {
            client,
            homeserver_url,
            http: reqwest::Client::new(),
            signals: StdMutex::new(None),
            listening: AtomicBool::new(false),
            call_room: StdMutex::new(None),
            seen: StdMutex::new(Seen::default()),
            reading: StdMutex::new(HashMap::new()),
            config: StdMutex::new(None),
        }))
    }

    /// Sends the bridge's call events to `signals`, replacing any earlier
    /// listener, and starts reading them the first time.
    pub(crate) fn subscribe_signals(self: &Arc<Self>, signals: StreamSink<CallSignal>) {
        *self.signals.lock().unwrap() = Some(signals);
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

    pub(crate) fn set_call_room(&self, room_id: Option<&str>) -> Result<()> {
        *self.call_room.lock().unwrap() = room_id.map(RoomId::parse).transpose()?;
        Ok(())
    }

    /// Posts a call event in `room_id` for the bridge to send to Signal.
    pub(crate) async fn send_signal(&self, room_id: &str, signal: CallSignal) -> Result<()> {
        let room_id = RoomId::parse(room_id)?;
        let room = self.client.get_room(&room_id).ok_or_else(|| anyhow!("unknown room"))?;
        room.send_raw(EVENT_TYPE, serde_json::to_value(to_content(signal))?).await?;
        Ok(())
    }

    /// The bridge's Signal device ID and Signal's TURN servers.
    pub(crate) async fn settings(&self) -> Result<CallSettings> {
        let config = self.config().await?;
        Ok(CallSettings { device_id: config.device_id, ice_servers: config.ice_servers() })
    }

    // The app runs the calls themselves, so the rest of the Linux service's
    // surface does nothing here.

    pub(crate) fn subscribe(self: &Arc<Self>, _updates: StreamSink<CallUpdate>) {}

    pub(crate) async fn place_call(&self, _room_id: &str, _video: bool) -> Result<()> {
        bail!(ELSEWHERE)
    }

    pub(crate) fn accept(&self, _call_id: &str, _video: bool) -> Result<()> {
        bail!(ELSEWHERE)
    }

    pub(crate) fn hang_up(&self) {}

    pub(crate) fn set_muted(&self, _muted: bool) -> Result<()> {
        bail!(ELSEWHERE)
    }

    pub(crate) fn set_video(&self, _enabled: bool) -> Result<()> {
        bail!(ELSEWHERE)
    }

    pub(crate) fn remote_frame(&self, _max_width: u32, _max_height: u32) -> Option<CallFrame> {
        None
    }

    pub(crate) fn local_frame(&self, _max_width: u32, _max_height: u32) -> Option<CallFrame> {
        None
    }

    fn on_sync_event(self: &Arc<Self>, event: &Raw<AnySyncTimelineEvent>, room: Room) {
        if event.get_field::<OwnedUserId>("sender").ok().flatten().as_deref() == self.client.user_id() {
            return;
        }
        let is_call_event = event.get_field::<String>("type").ok().flatten().as_deref() == Some(EVENT_TYPE);
        let in_call = self.call_room.lock().unwrap().as_deref() == Some(room.room_id());
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
            let signal = raw
                .get_field::<Content>("content")
                .map_err(anyhow::Error::from)
                .and_then(|content| content.ok_or_else(|| anyhow!("no content")))
                .and_then(|content| to_signal(room.room_id(), content, now, sent_ms));
            match signal {
                Ok(Some(signal)) => {
                    if let Some(sink) = self.signals.lock().unwrap().as_ref() {
                        let _ = sink.add(signal);
                    }
                }
                Ok(None) => {}
                Err(e) => tracing::warn!("call event {event_id}: {e:#}"),
            }
        }
        Ok(())
    }

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

/// An event from the bridge, checked as `content::received` checks it on
/// Linux. RingRTC drops offers a minute old, so an offer's age runs from
/// when Signal's server took it, or from `sent_ms`, the event's own time,
/// if the bridge didn't say. Opaque messages (group call rings) give `None`.
fn to_signal(room_id: &RoomId, content: Content, now_ms: u64, sent_ms: u64) -> Result<Option<CallSignal>> {
    let kind = match content.kind {
        Kind::Offer => CallSignalKind::Offer,
        Kind::Answer => CallSignalKind::Answer,
        Kind::Ice => CallSignalKind::Ice,
        Kind::Busy => CallSignalKind::Busy,
        Kind::Hangup => CallSignalKind::Hangup,
        Kind::Opaque => return Ok(None),
    };
    if content.call_id.parse::<u64>().is_err() {
        bail!("invalid call_id {:?}", content.call_id);
    }
    if content.sender_device_id == 0 {
        bail!("no sender_device_id");
    }
    if matches!(kind, CallSignalKind::Offer | CallSignalKind::Answer)
        && (content.sender_identity_key.len() != 32 || content.receiver_identity_key.len() != 32)
    {
        bail!("identity keys must be 32 bytes");
    }
    if kind == CallSignalKind::Offer && !matches!(content.offer_type, 0 | 1) {
        bail!("unknown offer_type {}", content.offer_type);
    }
    if kind == CallSignalKind::Hangup && !(0..=4).contains(&content.hangup_type) {
        bail!("unknown hangup_type {}", content.hangup_type);
    }
    let taken_ms = if content.server_ts > 0 { content.server_ts } else { sent_ms };
    Ok(Some(CallSignal {
        room_id: room_id.to_string(),
        kind,
        call_id: content.call_id,
        sender_device_id: content.sender_device_id,
        receiver_device_id: content.receiver_device_id,
        age_secs: u32::try_from(now_ms.saturating_sub(taken_ms) / 1000).unwrap_or(u32::MAX),
        sender_identity_key: content.sender_identity_key,
        receiver_identity_key: content.receiver_identity_key,
        destination_device_id: None,
        video: content.offer_type == 1,
        hangup_type: content.hangup_type,
        hangup_device_id: content.hangup_device_id,
        opaque: content.opaque,
        candidates: content.candidates,
    }))
}

/// The event for a signal RingRTC wants sent.
fn to_content(signal: CallSignal) -> Content {
    Content {
        kind: match signal.kind {
            CallSignalKind::Offer => Kind::Offer,
            CallSignalKind::Answer => Kind::Answer,
            CallSignalKind::Ice => Kind::Ice,
            CallSignalKind::Busy => Kind::Busy,
            CallSignalKind::Hangup => Kind::Hangup,
        },
        call_id: signal.call_id,
        sender_device_id: 0,
        receiver_device_id: 0,
        server_ts: 0,
        sender_identity_key: Vec::new(),
        receiver_identity_key: Vec::new(),
        destination_device_id: signal.destination_device_id,
        offer_type: if signal.kind == CallSignalKind::Offer && signal.video { 1 } else { 0 },
        hangup_type: signal.hangup_type,
        hangup_device_id: signal.hangup_device_id,
        opaque: signal.opaque,
        candidates: signal.candidates,
        urgency: 0,
    }
}

/// `GET /v3/calls/config` on the Signal bridge. Same as `service.rs`'s.
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

impl CallsConfig {
    /// As Signal Desktop does: the IP URLs first, with the hostname for TLS,
    /// then the named ones.
    fn ice_servers(&self) -> Vec<IceServerSpec> {
        let mut servers = Vec::new();
        for relay in self.relays.iter().flatten() {
            for (hostname, urls) in [(&relay.hostname, &relay.urls_with_ips), (&String::new(), &relay.urls)] {
                if !urls.is_empty() {
                    servers.push(IceServerSpec {
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

/// Event IDs already passed on, the newest thousand.
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

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn room() -> OwnedRoomId {
        RoomId::parse("!dm:switchboard.internal").unwrap()
    }

    fn parse(value: serde_json::Value) -> Content {
        serde_json::from_value(value).unwrap()
    }

    /// A 32-byte identity key, as the bridge writes it.
    fn key(byte: u8) -> String {
        use base64::{engine::general_purpose::STANDARD, Engine};
        STANDARD.encode([byte; 32])
    }

    #[test]
    fn reads_offers_dated_from_signal() {
        let content = parse(json!({
            "kind": "offer", "call_id": "18446744073709551615", "sender_device_id": 2, "receiver_device_id": 3,
            "server_ts": 10_000, "offer_type": 1, "opaque": "AQI=",
            "sender_identity_key": key(1), "receiver_identity_key": key(2),
        }));
        let signal = to_signal(&room(), content, 13_500, 12_000).unwrap().unwrap();
        assert_eq!(signal.kind, CallSignalKind::Offer);
        assert_eq!(signal.call_id, "18446744073709551615");
        assert_eq!((signal.sender_device_id, signal.receiver_device_id), (2, 3));
        assert_eq!(signal.age_secs, 3, "from Signal's server time, not the event's");
        assert!(signal.video);
        assert_eq!(signal.opaque, vec![1, 2]);
        assert_eq!(signal.sender_identity_key.len(), 32);
        assert_eq!(signal.room_id, "!dm:switchboard.internal");
    }

    #[test]
    fn dates_offers_from_the_event_without_a_server_time() {
        let content = parse(json!({
            "kind": "offer", "call_id": "7", "sender_device_id": 1,
            "sender_identity_key": key(1), "receiver_identity_key": key(2),
        }));
        let signal = to_signal(&room(), content, 13_500, 12_000).unwrap().unwrap();
        assert_eq!(signal.age_secs, 1);
        assert!(!signal.video);
    }

    #[test]
    fn reads_ice_and_hangups() {
        let ice = parse(json!({"kind": "ice", "call_id": "7", "sender_device_id": 2, "candidates": ["AQ==", "Ag=="]}));
        let signal = to_signal(&room(), ice, 0, 0).unwrap().unwrap();
        assert_eq!(signal.candidates, vec![vec![1], vec![2]]);
        let hangup = parse(json!({
            "kind": "hangup", "call_id": "7", "sender_device_id": 2, "hangup_type": 2, "hangup_device_id": 3,
        }));
        let signal = to_signal(&room(), hangup, 0, 0).unwrap().unwrap();
        assert_eq!((signal.hangup_type, signal.hangup_device_id), (2, Some(3)));
    }

    #[test]
    fn skips_opaque_messages_and_rejects_bad_events() {
        assert!(to_signal(&room(), parse(json!({"kind": "opaque", "opaque": "AQ=="})), 0, 0).unwrap().is_none());
        for value in [
            json!({"kind": "ice", "call_id": "x", "sender_device_id": 1}),
            json!({"kind": "ice", "call_id": "7"}),
            json!({"kind": "answer", "call_id": "7", "sender_device_id": 1, "sender_identity_key": "AQ=="}),
            json!({"kind": "offer", "call_id": "7", "sender_device_id": 1, "offer_type": 5,
                "sender_identity_key": key(1), "receiver_identity_key": key(2)}),
            json!({"kind": "hangup", "call_id": "7", "sender_device_id": 1, "hangup_type": 9}),
        ] {
            assert!(to_signal(&room(), parse(value.clone()), 0, 0).is_err(), "{value}");
        }
    }

    #[test]
    fn writes_what_the_bridge_reads() {
        let signal = |kind| CallSignal {
            room_id: String::new(),
            kind,
            call_id: "18446744073709551615".into(),
            sender_device_id: 9,
            receiver_device_id: 9,
            age_secs: 9,
            sender_identity_key: vec![9],
            receiver_identity_key: vec![9],
            destination_device_id: Some(2),
            video: true,
            hangup_type: 0,
            hangup_device_id: None,
            opaque: vec![1, 2],
            candidates: Vec::new(),
        };
        // What the app knows about the contact's side isn't sent back.
        assert_eq!(
            serde_json::to_value(to_content(signal(CallSignalKind::Offer))).unwrap(),
            json!({"kind": "offer", "call_id": "18446744073709551615", "destination_device_id": 2,
                "offer_type": 1, "opaque": "AQI="}),
        );
        let hangup = CallSignal {
            hangup_type: 1,
            hangup_device_id: Some(3),
            opaque: Vec::new(),
            destination_device_id: None,
            ..signal(CallSignalKind::Hangup)
        };
        assert_eq!(
            serde_json::to_value(to_content(hangup)).unwrap(),
            json!({"kind": "hangup", "call_id": "18446744073709551615", "hangup_type": 1, "hangup_device_id": 3}),
        );
        let ice = CallSignal { candidates: vec![vec![1], vec![2, 3]], opaque: Vec::new(), ..signal(CallSignalKind::Ice) };
        assert_eq!(
            serde_json::to_value(to_content(ice)).unwrap(),
            json!({"kind": "ice", "call_id": "18446744073709551615", "destination_device_id": 2,
                "candidates": ["AQ==", "AgM="]}),
        );
    }

    #[test]
    fn lists_ip_urls_first_with_the_hostname() {
        let config: CallsConfig = serde_json::from_value(json!({
            "device_id": 3,
            "relays": [{"username": "u", "password": "p", "hostname": "turn.example",
                "urls": ["turn:turn.example"], "urlsWithIps": ["turn:192.0.2.1"]}],
        }))
        .unwrap();
        let servers = config.ice_servers();
        assert_eq!(servers.len(), 2);
        assert_eq!((servers[0].hostname.as_str(), servers[0].urls[0].as_str()), ("turn.example", "turn:192.0.2.1"));
        assert_eq!((servers[1].hostname.as_str(), servers[1].urls[0].as_str()), ("", "turn:turn.example"));
    }
}
