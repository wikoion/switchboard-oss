//! Signal 1:1 calls with audio and video. On Linux the core runs them; on
//! iOS the app does, with Signal's Swift package, and the core carries the
//! call events (`subscribe_signals`, `send_signal`). Elsewhere `supported`
//! is false.

use std::sync::Arc;

#[cfg(target_os = "linux")]
use anyhow::anyhow;
use anyhow::Result;
use flutter_rust_bridge::frb;

use crate::{api::client::SwitchboardCore, calls::CallService, frb_generated::StreamSink, runtime};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CallPhase {
    Incoming,
    Outgoing,
    Ringing,
    Connecting,
    Connected,
    Ended,
}

/// A change to a call, for the ring and in-call screens.
#[derive(Clone, Debug)]
pub struct CallUpdate {
    /// The Signal DM the call is in.
    pub room_id: String,
    pub call_id: String,
    pub phase: CallPhase,
    /// It was placed as a video call.
    pub video: bool,
    /// The contact's camera is on.
    pub remote_video: bool,
    /// For `Ended`: RingRTC's reason, such as `RemoteHangup` or `Timeout`.
    pub reason: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CallSignalKind {
    Offer,
    Answer,
    Ice,
    Busy,
    Hangup,
}

/// A call event, from the contact's Signal devices or to them (iOS). Enum
/// numbers are Signal's and RingRTC's: `hangup_type` normal 0, accepted 1,
/// declined 2, busy 3, need permission 4 on another device.
#[derive(Clone, Debug)]
pub struct CallSignal {
    /// The Signal DM it's in.
    pub room_id: String,
    pub kind: CallSignalKind,
    /// A u64 in decimal.
    pub call_id: String,
    /// The contact's sending device, and the bridge's own device it was for.
    /// Not used on events sent.
    pub sender_device_id: u32,
    pub receiver_device_id: u32,
    /// Seconds since Signal's server took it. RingRTC drops offers a minute
    /// old. Not used on events sent.
    pub age_secs: u32,
    /// On offers and answers received: 32 bytes each, without the type byte.
    pub sender_identity_key: Vec<u8>,
    pub receiver_identity_key: Vec<u8>,
    /// On events sent to one of the contact's devices rather than all.
    pub destination_device_id: Option<u32>,
    /// An offer for a video call.
    pub video: bool,
    pub hangup_type: i32,
    pub hangup_device_id: Option<u32>,
    pub opaque: Vec<u8>,
    pub candidates: Vec<Vec<u8>>,
}

/// What RingRTC needs from the bridge: its Signal device ID, and Signal's
/// TURN servers.
#[derive(Clone, Debug)]
pub struct CallSettings {
    pub device_id: u32,
    pub ice_servers: Vec<IceServerSpec>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct IceServerSpec {
    pub username: String,
    pub password: String,
    /// For TLS to the IP URLs; empty for named ones.
    pub hostname: String,
    pub urls: Vec<String>,
}

/// One video frame to draw: `width` by `height` pixels, 4 bytes each.
pub struct CallFrame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

#[frb(opaque)]
pub struct SignalCalls {
    service: Arc<CallService>,
}

impl SignalCalls {
    #[frb(sync)]
    pub fn supported() -> bool {
        cfg!(any(target_os = "linux", target_os = "ios"))
    }

    /// Sets up calls for `core`'s Signal account. They're taken once
    /// something subscribes.
    pub async fn start(core: &SwitchboardCore) -> Result<SignalCalls> {
        let client = core.matrix_client();
        let homeserver_url = core.homeserver_url();
        let service = runtime::run(async move { CallService::start(client, homeserver_url) }).await?;
        Ok(SignalCalls { service })
    }

    /// Streams updates for every call, and starts taking calls. A second
    /// subscriber replaces the first.
    pub async fn subscribe(&self, sink: StreamSink<CallUpdate>) -> Result<()> {
        let service = self.service.clone();
        runtime::run(async move {
            service.subscribe(sink);
            Ok(())
        })
        .await
    }

    /// Rings the contact in `room_id`, a Signal DM. With `video`, the camera
    /// starts first, so a missing or busy camera fails here.
    pub async fn place_call(&self, room_id: String, video: bool) -> Result<()> {
        let service = self.service.clone();
        runtime::run(async move { service.place_call(&room_id, video).await }).await
    }

    /// Answers `call_id`, with the camera on if `video`. Only then does the
    /// call connect, and it's accepted once RingRTC rings.
    pub async fn accept(&self, call_id: String, video: bool) -> Result<()> {
        let service = self.service.clone();
        runtime::run(async move { service.accept(&call_id, video) }).await
    }

    /// Ends the call, or declines it while it rings.
    pub async fn hang_up(&self) -> Result<()> {
        let service = self.service.clone();
        runtime::run(async move {
            service.hang_up();
            Ok(())
        })
        .await
    }

    pub async fn set_muted(&self, muted: bool) -> Result<()> {
        let service = self.service.clone();
        runtime::run(async move { service.set_muted(muted) }).await
    }

    /// Turns the camera on or off during a call.
    pub async fn set_video(&self, enabled: bool) -> Result<()> {
        let service = self.service.clone();
        runtime::run(async move { service.set_video(enabled) }).await
    }

    /// The contact's newest frame since the last call, if any, shrunk to fit.
    pub fn remote_frame(&self, max_width: u32, max_height: u32) -> Option<CallFrame> {
        self.service.remote_frame(max_width, max_height)
    }

    /// The camera's newest frame since the last call, if any, shrunk to fit.
    pub fn local_frame(&self, max_width: u32, max_height: u32) -> Option<CallFrame> {
        self.service.local_frame(max_width, max_height)
    }

    // Where the app runs RingRTC (iOS). On Linux these fail.

    /// Streams the bridge's call events for the app's RingRTC, in order and
    /// once each. A second subscriber replaces the first.
    #[allow(clippy::needless_return)]
    pub async fn subscribe_signals(&self, sink: StreamSink<CallSignal>) -> Result<()> {
        #[cfg(target_os = "linux")]
        let _ = sink;
        #[cfg(target_os = "linux")]
        return Err(anyhow!(IN_CORE));
        #[cfg(not(target_os = "linux"))]
        return {
            let service = self.service.clone();
            runtime::run(async move {
                service.subscribe_signals(sink);
                Ok(())
            })
            .await
        };
    }

    /// Sends a call event to the contact. Returns once the server has it,
    /// which is when RingRTC is told the message was sent.
    #[allow(clippy::needless_return)]
    pub async fn send_signal(&self, signal: CallSignal) -> Result<()> {
        #[cfg(target_os = "linux")]
        let _ = signal;
        #[cfg(target_os = "linux")]
        return Err(anyhow!(IN_CORE));
        #[cfg(not(target_os = "linux"))]
        return {
            let service = self.service.clone();
            runtime::run(async move { service.send_signal(&signal.room_id.clone(), signal).await }).await
        };
    }

    /// The bridge's device ID and the TURN servers, cached for 5 minutes.
    #[allow(clippy::needless_return)]
    pub async fn settings(&self) -> Result<CallSettings> {
        #[cfg(target_os = "linux")]
        return Err(anyhow!(IN_CORE));
        #[cfg(not(target_os = "linux"))]
        return {
            let service = self.service.clone();
            runtime::run(async move { service.settings().await }).await
        };
    }

    /// The chat of the call in progress, or none. Every new event there is
    /// read for call events, which can hide behind a message in one sync.
    #[allow(clippy::needless_return)]
    pub async fn set_call_room(&self, room_id: Option<String>) -> Result<()> {
        #[cfg(target_os = "linux")]
        let _ = room_id;
        #[cfg(target_os = "linux")]
        return Err(anyhow!(IN_CORE));
        #[cfg(not(target_os = "linux"))]
        return {
            let service = self.service.clone();
            runtime::run(async move { service.set_call_room(room_id.as_deref()) }).await
        };
    }
}

#[cfg(target_os = "linux")]
const IN_CORE: &str = "Linux runs calls in the core";
