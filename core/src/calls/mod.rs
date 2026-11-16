//! Signal 1:1 calls. The Signal bridge relays Signal's call signalling as
//! room events in the DM portal, and RingRTC runs in the app, so audio and
//! video go straight between this device and the contact. On Linux RingRTC
//! runs here (`service.rs`); on iOS it runs in Swift, and the core only
//! carries the events (`relay.rs`).

/// Room event carrying call signalling between the Signal bridge and the
/// app. The bridge's side is `bridges/signal/overlay/pkg/signalcall`.
pub(crate) const EVENT_TYPE: &str = "app.switchboard.signal.call";

#[cfg(target_os = "linux")]
mod camera;
mod content;
#[cfg(target_os = "linux")]
mod service;
#[cfg(target_os = "linux")]
mod video;
#[cfg(not(target_os = "linux"))]
mod relay;
#[cfg(all(test, target_os = "linux"))]
mod loopback;

#[cfg(target_os = "linux")]
pub(crate) use service::CallService;
#[cfg(not(target_os = "linux"))]
pub(crate) use relay::CallService;
