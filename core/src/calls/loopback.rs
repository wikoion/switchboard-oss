//! Two RingRTC call managers in one process call each other. Every message
//! goes through the call event's JSON and a stand-in for the bridge, as in
//! production. The callee rings a while before it answers, and only proceeds
//! then, as the service does. Once connected, the caller sends generated
//! video. Ignored by
//! default: it opens audio devices and sockets. To keep sound off the
//! speakers and the microphone out of it:
//!
//! ```text
//! pactl load-module module-null-sink sink_name=sb_test
//! env PULSE_SINK=sb_test PULSE_SOURCE=sb_test.monitor cargo test --lib loopback -- --ignored
//! pactl unload-module <id>
//! ```

use std::{
    collections::{HashMap, HashSet},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use anyhow::{bail, Result};
use ringrtc::{
    common::{CallConfig, CallId, CallMediaType, DeviceId},
    core::{call_manager::CallManager, group_call, signaling},
    lite::{http, sfu::UserId},
    native::{CallState, CallStateHandler, NativeCallContext, NativePlatform, SignalingSender},
    webrtc::{
        media::{AudioTrack, VideoFrame, VideoPixelFormat, VideoSource, VideoTrack},
        peer_connection::AudioLevel,
        peer_connection_factory::{AudioConfig, PeerConnectionFactory},
        peer_connection_observer::NetworkRoute,
    },
};

use super::{
    content::{self, Content, Kind},
    service::{deliver, now_ms, NoGroupCalls, NoHttp},
    video::{self, FrameSlot},
};

const PEERS: [&str; 2] = ["caller", "callee"];
// The callee isn't device 1, which signal-cli's relay got wrong.
const DEVICES: [DeviceId; 2] = [1, 3];
/// How long each send takes, as if over the network.
const SEND_TIME: Duration = Duration::from_millis(50);
/// How long the callee rings before Answer is pressed.
const ANSWER_TIME: Duration = Duration::from_secs(2);
/// The caller's generated video: 640x480 at about 30 fps.
const FRAME: (u32, u32) = (640, 480);
const FRAME_TIME: Duration = Duration::from_millis(33);

enum Event {
    Send { from: usize, call_id: CallId, destination: Option<DeviceId>, message: signaling::Message },
    State { side: usize, call_id: CallId, state: String },
    RemoteVideo { side: usize, enabled: bool },
}

struct Side {
    manager: CallManager<NativePlatform>,
    audio: AudioTrack,
    video: VideoTrack,
    source: VideoSource,
    /// The other side's video, as it arrives.
    frames: FrameSlot,
    key: Vec<u8>,
}

fn side(index: usize, events: &mpsc::Sender<Event>) -> Result<Side> {
    let factory = PeerConnectionFactory::new(&AudioConfig::default(), false, "", None)?;
    let audio = factory.create_outgoing_audio_track()?;
    audio.set_enabled(false);
    let source = factory.create_outgoing_video_source()?;
    let video = factory.create_outgoing_video_track(&source)?;
    video.set_enabled(false);
    let platform = NativePlatform::new(
        factory,
        Box::new(Signaling(index, events.clone())),
        false,
        Box::new(States(index, events.clone())),
        Box::new(NoGroupCalls),
    );
    let manager = CallManager::new(platform, http::DelegatingClient::new(NoHttp))?;
    Ok(Side { manager, audio, video, source, frames: FrameSlot::default(), key: vec![index as u8 + 1; 32] })
}

/// A message as the bridge relays it: through the event's JSON, dropped if
/// it's for another device, then given the bridge's fields.
fn relay(
    sides: &[Side; 2],
    from: usize,
    call_id: CallId,
    destination: Option<DeviceId>,
    message: signaling::Message,
) -> Result<Option<Content>> {
    let to = 1 - from;
    let event = serde_json::to_string(&content::from_message(call_id, destination, message))?;
    let mut content: Content = serde_json::from_str(&event)?;
    if content.destination_device_id.is_some_and(|d| d != DEVICES[to]) {
        return Ok(None);
    }
    content.destination_device_id = None;
    content.sender_device_id = DEVICES[from];
    content.receiver_device_id = DEVICES[to];
    content.server_ts = now_ms();
    if matches!(content.kind, Kind::Offer | Kind::Answer) {
        content.sender_identity_key = sides[from].key.clone();
        content.receiver_identity_key = sides[to].key.clone();
    }
    Ok(Some(content))
}

#[test]
#[ignore = "opens audio devices and sockets; see the module docs"]
fn two_call_managers_connect_through_call_events() -> Result<()> {
    let (events, queue) = mpsc::channel();
    let mut sides = [side(0, &events)?, side(1, &events)?];
    sides[0].manager.call(PEERS[1].to_owned(), CallMediaType::Video, DEVICES[0]);
    let grey = vec![128; (FRAME.0 * FRAME.1 * 3 / 2) as usize];

    let mut relayed = Vec::new();
    let (mut ice_messages, mut candidates) = (0, 0);
    let mut connected = [false; 2];
    let mut sending_video = false;
    let mut remote_video = false;
    let mut received: Option<(u32, u32)> = None;
    let mut ended: [Option<String>; 2] = [None, None];
    let mut hung_up = false;
    let started = Instant::now();
    let mut answer_at: Option<(CallId, Instant)> = None;
    let mut answer_sent = None;
    let deadline = started + Duration::from_secs(30);
    while ended.iter().any(Option::is_none) {
        if Instant::now() > deadline {
            bail!("stuck: connected {connected:?}, remote video {remote_video}, received {received:?}, relayed {relayed:?}");
        }
        // While video goes, wake for each frame.
        let mut wait = if sending_video && !hung_up { FRAME_TIME } else { deadline.saturating_duration_since(Instant::now()) };
        if let Some((_, at)) = answer_at {
            wait = wait.min(at.saturating_duration_since(Instant::now()));
        }
        let Ok(event) = queue.recv_timeout(wait) else {
            if let Some((call_id, at)) = answer_at
                && Instant::now() >= at
            {
                answer_at = None;
                proceed(&mut sides[1], call_id);
            }
            if sending_video {
                send_frame(&mut sides, &grey, &mut received, &mut hung_up, remote_video);
            }
            continue;
        };
        match event {
            Event::Send { from, call_id, destination, message } => {
                thread::sleep(SEND_TIME);
                let content = relay(&sides, from, call_id, destination, message)?;
                sides[from].manager.message_sent(call_id);
                let Some(content) = content else {
                    continue;
                };
                if content.kind == Kind::Ice {
                    ice_messages += 1;
                    candidates += content.candidates.len();
                }
                if content.kind == Kind::Answer {
                    answer_sent = Some(started.elapsed());
                }
                relayed.push(content.kind);
                if let Some(received) = content::received(content, now_ms(), now_ms())? {
                    deliver(&mut sides[1 - from].manager, PEERS[from].to_owned(), received);
                }
            }
            Event::State { side, call_id, state } => match state.as_str() {
                "Outgoing" => proceed(&mut sides[side], call_id),
                "Incoming" => answer_at = Some((call_id, Instant::now() + ANSWER_TIME)),
                "Ringing" if side == 1 => sides[1].manager.accept_call(call_id),
                "Connected" => connected[side] = true,
                ended_state if ended_state.starts_with("Ended") => {
                    if !hung_up {
                        bail!("{} ended before the hangup: {ended_state}", PEERS[side]);
                    }
                    ended[side] = Some(ended_state.to_owned());
                }
                rejected if rejected.starts_with("Rejected") => bail!("{} {rejected}", PEERS[side]),
                _ => {}
            },
            Event::RemoteVideo { side: 1, enabled } => remote_video = enabled,
            Event::RemoteVideo { .. } => {}
        }
        if connected == [true; 2] && !sending_video {
            // As the service does once connected with the camera on.
            sending_video = true;
            sides[0].video.set_enabled(true);
            let mut connection = sides[0].manager.active_connection()?;
            connection.update_sender_status(signaling::SenderStatus { video_enabled: Some(true), ..Default::default() })?;
        }
        if sending_video {
            send_frame(&mut sides, &grey, &mut received, &mut hung_up, remote_video);
        }
    }

    for kind in [Kind::Offer, Kind::Answer, Kind::Ice, Kind::Hangup] {
        assert!(relayed.contains(&kind), "{kind:?} never relayed: {relayed:?}");
    }
    // Candidates found during a send go out together in the next one.
    assert!(ice_messages < candidates, "{candidates} candidates in {ice_messages} ICE messages");
    // Nothing answers the caller until Answer is pressed.
    let answer_sent = answer_sent.unwrap();
    assert!(answer_sent >= ANSWER_TIME, "answered after {answer_sent:?}, before Answer was pressed");
    // The encoder may start smaller, but keeps the shape.
    let (width, height) = received.unwrap();
    let shape = |w: u32, h: u32| w as f64 / h as f64;
    assert!(
        width <= FRAME.0 && (shape(width, height) - shape(FRAME.0, FRAME.1)).abs() < 0.02,
        "sent {}x{}, received {width}x{height}",
        FRAME.0,
        FRAME.1,
    );
    assert_eq!(ended[0].as_deref(), Some("Ended LocalHangup"));
    assert_eq!(ended[1].as_deref(), Some("Ended RemoteHangup"));
    for s in &mut sides {
        s.manager.close()?;
    }
    Ok(())
}

/// As the service does, without TURN servers.
fn proceed(side: &mut Side, call_id: CallId) {
    let frames = Box::new(side.frames.clone());
    let context = NativeCallContext::new(false, Vec::new(), side.audio.clone(), side.video.clone(), frames);
    side.manager.proceed(call_id, context, CallConfig::default(), None);
}

/// Sends the caller's next frame, notes the size of a grey one the callee
/// got (not WebRTC's black filler), and hangs up once the callee has one and
/// the caller's camera-on status.
fn send_frame(sides: &mut [Side; 2], grey: &[u8], received: &mut Option<(u32, u32)>, hung_up: &mut bool, remote_video: bool) {
    if *hung_up {
        return;
    }
    sides[0].source.push_frame(VideoFrame::copy_from_slice(FRAME.0, FRAME.1, VideoPixelFormat::I420, grey));
    if let Some(frame) = sides[1].frames.take().and_then(|f| video::to_rgba(f, FRAME.0, FRAME.1)) {
        let middle = (frame.height as usize / 2 * frame.width as usize + frame.width as usize / 2) * 4;
        if frame.rgba[middle..middle + 3].iter().all(|&c| (100..=156).contains(&c)) {
            *received = Some((frame.width, frame.height));
        }
    }
    if remote_video && received.is_some() {
        *hung_up = true;
        sides[0].manager.hangup();
    }
}

struct Signaling(usize, mpsc::Sender<Event>);

impl SignalingSender for Signaling {
    fn send_signaling(
        &self,
        _: &str,
        call_id: CallId,
        destination: Option<DeviceId>,
        message: signaling::Message,
    ) -> Result<()> {
        let _ = self.1.send(Event::Send { from: self.0, call_id, destination, message });
        Ok(())
    }

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

struct States(usize, mpsc::Sender<Event>);

impl CallStateHandler for States {
    fn handle_call_state(&self, _: &str, call_id: CallId, state: CallState) -> Result<()> {
        let state = match state {
            CallState::Incoming(_) => "Incoming".to_owned(),
            CallState::Outgoing(_) => "Outgoing".to_owned(),
            CallState::Ringing => "Ringing".to_owned(),
            CallState::Connecting => "Connecting".to_owned(),
            CallState::Connected => "Connected".to_owned(),
            CallState::Ended(reason, _) => format!("Ended {reason:?}"),
            CallState::Rejected(reason) => format!("Rejected {reason:?}"),
            CallState::Concluded => "Concluded".to_owned(),
        };
        let _ = self.1.send(Event::State { side: self.0, call_id, state });
        Ok(())
    }

    fn handle_remote_audio_state(&self, _: &str, _: bool) -> Result<()> {
        Ok(())
    }

    fn handle_remote_video_state(&self, _: &str, enabled: bool) -> Result<()> {
        let _ = self.1.send(Event::RemoteVideo { side: self.0, enabled });
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
