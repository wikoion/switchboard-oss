//! The call event's content, and on Linux turning it into what RingRTC
//! takes and back (on iOS, Swift does that). Field names and enum numbers
//! match the bridge's `signalcall.Content`, whose numbers are Signal's
//! `CallMessage` proto's, which are also RingRTC's.

#[cfg(target_os = "linux")]
use std::time::Duration;

#[cfg(target_os = "linux")]
use anyhow::{anyhow, bail, Result};
#[cfg(target_os = "linux")]
use ringrtc::{
    common::{CallId, CallMediaType, DeviceId},
    core::signaling,
};
use serde::{Deserialize, Serialize};

/// RingRTC's, a Signal device number.
#[cfg(not(target_os = "linux"))]
pub(super) type DeviceId = u32;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Kind {
    Offer,
    Answer,
    Ice,
    Busy,
    Hangup,
    Opaque,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub(super) struct Content {
    pub kind: Kind,
    /// Decimal, because Matrix JSON can't hold every u64. Opaque messages
    /// have none.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub call_id: String,

    // Set by the bridge on events from Signal. The identity keys come on
    // offers and answers, 32 bytes without the type byte.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub sender_device_id: DeviceId,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub receiver_device_id: DeviceId,
    /// When Signal's server took the message, in ms.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub server_ts: u64,
    #[serde(default, with = "b64", skip_serializing_if = "Vec::is_empty")]
    pub sender_identity_key: Vec<u8>,
    #[serde(default, with = "b64", skip_serializing_if = "Vec::is_empty")]
    pub receiver_identity_key: Vec<u8>,

    /// Set on events to Signal meant for one of the contact's devices.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destination_device_id: Option<DeviceId>,

    #[serde(default, skip_serializing_if = "is_zero")]
    pub offer_type: i32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub hangup_type: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hangup_device_id: Option<DeviceId>,
    #[serde(default, with = "b64", skip_serializing_if = "Vec::is_empty")]
    pub opaque: Vec<u8>,
    #[serde(default, with = "b64_list", skip_serializing_if = "Vec::is_empty")]
    pub candidates: Vec<Vec<u8>>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub urgency: i32,
}

fn is_zero<T: Default + PartialEq>(v: &T) -> bool {
    *v == T::default()
}

#[cfg(target_os = "linux")]
impl Content {
    fn new(kind: Kind, call_id: CallId) -> Self {
        Content {
            kind,
            call_id: call_id.as_u64().to_string(),
            sender_device_id: 0,
            receiver_device_id: 0,
            server_ts: 0,
            sender_identity_key: Vec::new(),
            receiver_identity_key: Vec::new(),
            destination_device_id: None,
            offer_type: 0,
            hangup_type: 0,
            hangup_device_id: None,
            opaque: Vec::new(),
            candidates: Vec::new(),
            urgency: 0,
        }
    }
}

/// The event for a message RingRTC wants sent. `destination` is set when it
/// goes to one of the contact's devices rather than all of them.
#[cfg(target_os = "linux")]
pub(super) fn from_message(call_id: CallId, destination: Option<DeviceId>, message: signaling::Message) -> Content {
    let mut content = match message {
        signaling::Message::Offer(offer) => Content {
            offer_type: offer.call_media_type as i32,
            opaque: offer.opaque,
            ..Content::new(Kind::Offer, call_id)
        },
        signaling::Message::Answer(answer) => Content { opaque: answer.opaque, ..Content::new(Kind::Answer, call_id) },
        signaling::Message::Ice(ice) => Content {
            candidates: ice.candidates.into_iter().map(|c| c.opaque).collect(),
            ..Content::new(Kind::Ice, call_id)
        },
        signaling::Message::Hangup(hangup) => {
            let (typ, device_id) = hangup.to_type_and_device_id();
            Content { hangup_type: typ as i32, hangup_device_id: device_id, ..Content::new(Kind::Hangup, call_id) }
        }
        signaling::Message::Busy => Content::new(Kind::Busy, call_id),
    };
    content.destination_device_id = destination;
    content
}

/// What an event from the bridge tells RingRTC.
#[cfg(target_os = "linux")]
pub(super) enum Received {
    Offer(CallId, signaling::ReceivedOffer),
    Answer(CallId, signaling::ReceivedAnswer),
    Ice(CallId, signaling::ReceivedIce),
    Hangup(CallId, signaling::ReceivedHangup),
    Busy(CallId, signaling::ReceivedBusy),
}

/// Reads an event from the bridge. RingRTC drops offers a minute old, so an
/// offer's age runs from when Signal's server took it, or from `sent_ms`,
/// the event's own time, if the bridge didn't say. Opaque messages (group
/// call rings) give `None`.
#[cfg(target_os = "linux")]
pub(super) fn received(content: Content, now_ms: u64, sent_ms: u64) -> Result<Option<Received>> {
    if content.kind == Kind::Opaque {
        return Ok(None);
    }
    let call_id = CallId::new(
        content.call_id.parse().map_err(|_| anyhow!("invalid call_id {:?}", content.call_id))?,
    );
    let sender_device_id = content.sender_device_id;
    if sender_device_id == 0 {
        bail!("no sender_device_id");
    }
    let keys = |content: &Content| -> Result<()> {
        if content.sender_identity_key.len() != 32 || content.receiver_identity_key.len() != 32 {
            bail!("identity keys must be 32 bytes");
        }
        Ok(())
    };
    Ok(Some(match content.kind {
        Kind::Offer => {
            keys(&content)?;
            let media = match content.offer_type {
                0 => CallMediaType::Audio,
                1 => CallMediaType::Video,
                other => bail!("unknown offer_type {other}"),
            };
            let taken_ms = if content.server_ts > 0 { content.server_ts } else { sent_ms };
            Received::Offer(
                call_id,
                signaling::ReceivedOffer {
                    offer: signaling::Offer::new(media, content.opaque)?,
                    age: Duration::from_millis(now_ms.saturating_sub(taken_ms)),
                    sender_device_id,
                    receiver_device_id: content.receiver_device_id,
                    sender_identity_key: content.sender_identity_key,
                    receiver_identity_key: content.receiver_identity_key,
                },
            )
        }
        Kind::Answer => {
            keys(&content)?;
            Received::Answer(
                call_id,
                signaling::ReceivedAnswer {
                    answer: signaling::Answer::new(content.opaque)?,
                    sender_device_id,
                    sender_identity_key: content.sender_identity_key,
                    receiver_identity_key: content.receiver_identity_key,
                },
            )
        }
        Kind::Ice => Received::Ice(
            call_id,
            signaling::ReceivedIce {
                ice: signaling::Ice {
                    candidates: content.candidates.into_iter().map(signaling::IceCandidate::new).collect(),
                },
                sender_device_id,
            },
        ),
        Kind::Hangup => {
            let typ = signaling::HangupType::from_i32(content.hangup_type)
                .ok_or_else(|| anyhow!("unknown hangup_type {}", content.hangup_type))?;
            Received::Hangup(
                call_id,
                signaling::ReceivedHangup {
                    hangup: signaling::Hangup::from_type_and_device_id(typ, content.hangup_device_id.unwrap_or(0)),
                    sender_device_id,
                },
            )
        }
        Kind::Busy => Received::Busy(call_id, signaling::ReceivedBusy { sender_device_id }),
        Kind::Opaque => return Ok(None),
    }))
}

mod b64 {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use serde::{de::Error, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        STANDARD.decode(String::deserialize(d)?).map_err(D::Error::custom)
    }
}

mod b64_list {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use serde::{de::Error, ser::SerializeSeq, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(list: &[Vec<u8>], s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(list.len()))?;
        for bytes in list {
            seq.serialize_element(&STANDARD.encode(bytes))?;
        }
        seq.end()
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<Vec<u8>>, D::Error> {
        Vec::<String>::deserialize(d)?
            .into_iter()
            .map(|s| STANDARD.decode(s).map_err(D::Error::custom))
            .collect()
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use serde_json::json;

    const KEY_A: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    const KEY_B: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";

    fn parse(value: serde_json::Value) -> Content {
        serde_json::from_value(value).expect("content")
    }

    #[test]
    fn writes_what_the_bridge_reads() {
        let call_id = CallId::new(u64::MAX);
        let hangup = from_message(
            call_id,
            Some(2),
            signaling::Message::Hangup(signaling::Hangup::AcceptedOnAnotherDevice(3)),
        );
        assert_eq!(
            serde_json::to_value(&hangup).unwrap(),
            json!({
                "kind": "hangup",
                "call_id": "18446744073709551615",
                "destination_device_id": 2,
                "hangup_type": 1,
                "hangup_device_id": 3,
            })
        );
        let ice = from_message(
            call_id,
            None,
            signaling::Message::Ice(signaling::Ice {
                candidates: vec![signaling::IceCandidate::new(vec![1, 2]), signaling::IceCandidate::new(vec![3])],
            }),
        );
        assert_eq!(
            serde_json::to_value(&ice).unwrap(),
            json!({"kind": "ice", "call_id": "18446744073709551615", "candidates": ["AQI=", "Aw=="]})
        );
        let busy = from_message(call_id, None, signaling::Message::Busy);
        assert_eq!(serde_json::to_value(&busy).unwrap(), json!({"kind": "busy", "call_id": "18446744073709551615"}));
    }

    #[test]
    fn dates_offers_from_signal() {
        let content = parse(json!({
            "kind": "offer",
            "call_id": "7",
            "sender_device_id": 2,
            "receiver_device_id": 4,
            "server_ts": 10_000,
            "sender_identity_key": KEY_A,
            "receiver_identity_key": KEY_B,
            "offer_type": 1,
        }));
        let Some(Received::Offer(call_id, offer)) = received(content, 13_500, 12_000).unwrap() else {
            panic!("not an offer");
        };
        assert_eq!(call_id, CallId::new(7));
        assert_eq!(offer.age, Duration::from_millis(3_500));
        assert_eq!(offer.offer.call_media_type, CallMediaType::Video);
        assert_eq!((offer.sender_device_id, offer.receiver_device_id), (2, 4));
        assert_eq!(offer.sender_identity_key, vec![0; 32]);
        assert_eq!(offer.receiver_identity_key, vec![1; 32]);
    }

    #[test]
    fn dates_offers_from_the_event_without_a_server_time() {
        let content = parse(json!({
            "kind": "offer",
            "call_id": "7",
            "sender_device_id": 1,
            "sender_identity_key": KEY_A,
            "receiver_identity_key": KEY_B,
        }));
        let Some(Received::Offer(_, offer)) = received(content, 13_500, 12_000).unwrap() else {
            panic!("not an offer");
        };
        assert_eq!(offer.age, Duration::from_millis(1_500));
        assert_eq!(offer.offer.call_media_type, CallMediaType::Audio);
    }

    #[test]
    fn reads_hangups_from_another_device() {
        let content = parse(json!({
            "kind": "hangup",
            "call_id": "7",
            "sender_device_id": 1,
            "hangup_type": 2,
            "hangup_device_id": 3,
        }));
        let Some(Received::Hangup(_, hangup)) = received(content, 0, 0).unwrap() else {
            panic!("not a hangup");
        };
        assert_eq!(hangup.hangup, signaling::Hangup::DeclinedOnAnotherDevice(3));
        assert_eq!(hangup.sender_device_id, 1);
    }

    #[test]
    fn reads_ice_from_the_senders_device() {
        let content = parse(json!({
            "kind": "ice",
            "call_id": "7",
            "sender_device_id": 3,
            "candidates": ["AQI=", "Aw=="],
        }));
        let Some(Received::Ice(_, ice)) = received(content, 0, 0).unwrap() else {
            panic!("not ice");
        };
        assert_eq!(ice.sender_device_id, 3);
        let candidates: Vec<_> = ice.ice.candidates.into_iter().map(|c| c.opaque).collect();
        assert_eq!(candidates, vec![vec![1, 2], vec![3]]);
    }

    #[test]
    fn skips_opaque_messages() {
        let content = parse(json!({"kind": "opaque", "sender_device_id": 1, "opaque": "AQI="}));
        assert!(received(content, 0, 0).unwrap().is_none());
    }

    #[test]
    fn rejects_bad_events() {
        for value in [
            json!({"kind": "busy", "call_id": "-1", "sender_device_id": 1}),
            json!({"kind": "busy", "call_id": "7"}),
            json!({"kind": "hangup", "call_id": "7", "sender_device_id": 1, "hangup_type": 9}),
            json!({"kind": "offer", "call_id": "7", "sender_device_id": 1, "sender_identity_key": KEY_A, "receiver_identity_key": KEY_B, "offer_type": 2}),
            json!({"kind": "answer", "call_id": "7", "sender_device_id": 1, "sender_identity_key": "AQI="}),
        ] {
            assert!(received(parse(value.clone()), 0, 0).is_err(), "{value}");
        }
        assert!(serde_json::from_value::<Content>(json!({"kind": "ring"})).is_err());
    }
}
