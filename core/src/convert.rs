//! Turns matrix-sdk-ui values into the plain types in `api::types`.

use matrix_sdk::ruma::{
    events::room::message::MessageType, MilliSecondsSinceUnixEpoch, UserId,
};
use matrix_sdk_ui::timeline::{
    EventSendState, EventTimelineItem, LatestEventValue, MembershipChange, MsgLikeKind,
    Profile, TimelineDetails, TimelineItem as SdkItem, TimelineItemContent, TimelineItemKind as SdkKind,
    VirtualTimelineItem,
};

use crate::api::types::{
    BridgeStatus, EventBody, LinkPreview, EventItem, Preview, Reaction, ReplyPreview, SendState, ThreadSummary,
    TimelineItem,
    TimelineItemKind,
};

pub(crate) fn millis(ts: MilliSecondsSinceUnixEpoch) -> i64 {
    i64::from(ts.0)
}

fn profile_name(p: &TimelineDetails<Profile>) -> Option<String> {
    match p {
        TimelineDetails::Ready(p) => p.display_name.clone(),
        _ => None,
    }
}

fn profile_avatar(p: &TimelineDetails<Profile>) -> Option<String> {
    match p {
        TimelineDetails::Ready(p) => p.avatar_url.as_ref().map(|u| u.to_string()),
        _ => None,
    }
}

/// One line of text for a chat-list preview or a quoted reply.
pub(crate) fn content_text(content: &TimelineItemContent) -> String {
    match content {
        TimelineItemContent::MsgLike(m) => match &m.kind {
            MsgLikeKind::Message(msg) => match msg.msgtype() {
                MessageType::Image(_) => "📷 Photo".to_owned(),
                MessageType::Video(_) => "🎥 Video".to_owned(),
                MessageType::Audio(_) => "🎤 Audio".to_owned(),
                MessageType::File(f) => format!("📎 {}", f.body),
                MessageType::Location(_) => "📍 Location".to_owned(),
                MessageType::Emote(e) => format!("* {}", e.body),
                _ => msg.body().to_owned(),
            },
            MsgLikeKind::Sticker(_) => "Sticker".to_owned(),
            MsgLikeKind::Poll(p) => format!("📊 {}", p.fallback_text().unwrap_or_default()),
            MsgLikeKind::Redacted => "Message deleted".to_owned(),
            MsgLikeKind::UnableToDecrypt(_) => "Encrypted message".to_owned(),
            MsgLikeKind::Other(_) => "Unsupported message".to_owned(),
            MsgLikeKind::LiveLocation(_) => "📍 Live location".to_owned(),
        },
        TimelineItemContent::MembershipChange(c) => membership_text(
            c.display_name().as_deref(),
            c.user_id(),
            c.change(),
        ),
        TimelineItemContent::ProfileChange(_) => "Profile updated".to_owned(),
        _ => "Room updated".to_owned(),
    }
}

fn membership_text(name: Option<&str>, user: &UserId, change: Option<MembershipChange>) -> String {
    let who = name.map(str::to_owned).unwrap_or_else(|| user.localpart().to_owned());
    let what = match change {
        Some(MembershipChange::Joined | MembershipChange::InvitationAccepted) => "joined",
        Some(MembershipChange::Left) => "left",
        Some(MembershipChange::Invited) => "was invited",
        Some(MembershipChange::Kicked | MembershipChange::KickedAndBanned) => "was removed",
        Some(MembershipChange::Banned) => "was banned",
        _ => "changed membership",
    };
    format!("{who} {what}")
}

pub(crate) fn preview(value: LatestEventValue) -> Option<(Preview, i64)> {
    match value {
        LatestEventValue::None => None,
        LatestEventValue::Remote { timestamp, is_own, profile, content, .. } => Some((
            Preview {
                sender_name: profile_name(&profile),
                sender_avatar_mxc: profile_avatar(&profile),
                is_own,
                text: content_text(&content),
                sending: false,
                failed: false,
                is_membership: matches!(content, TimelineItemContent::MembershipChange(_)),
            },
            millis(timestamp),
        )),
        LatestEventValue::RemoteInvite { timestamp, inviter_profile, .. } => Some((
            Preview {
                sender_name: profile_name(&inviter_profile),
                sender_avatar_mxc: profile_avatar(&inviter_profile),
                is_own: false,
                text: "Invited you".to_owned(),
                sending: false,
                failed: false,
                is_membership: false,
            },
            millis(timestamp),
        )),
        LatestEventValue::Local { timestamp, profile, content, state, .. } => {
            use matrix_sdk_ui::timeline::LatestEventValueLocalState as S;
            Some((
                Preview {
                    sender_name: profile_name(&profile),
                    sender_avatar_mxc: profile_avatar(&profile),
                    is_own: true,
                    text: content_text(&content),
                    sending: matches!(state, S::IsSending),
                    failed: matches!(state, S::CannotBeSent),
                    is_membership: false,
                },
                millis(timestamp),
            ))
        }
    }
}

pub(crate) fn timeline_item(item: &SdkItem) -> TimelineItem {
    let kind = match item.kind() {
        SdkKind::Virtual(VirtualTimelineItem::DateDivider(ts)) => {
            TimelineItemKind::DateDivider { timestamp_ms: millis(*ts) }
        }
        SdkKind::Virtual(VirtualTimelineItem::ReadMarker) => TimelineItemKind::ReadMarker,
        SdkKind::Virtual(VirtualTimelineItem::TimelineStart) => TimelineItemKind::TimelineStart,
        SdkKind::Event(e) => TimelineItemKind::Event(event_item(e)),
    };
    TimelineItem { unique_id: item.unique_id().0.clone(), kind }
}

fn event_item(e: &EventTimelineItem) -> EventItem {
    let (thread, thread_root) = match e.content() {
        TimelineItemContent::MsgLike(m) => (
            m.thread_summary.as_ref().filter(|t| t.num_replies > 0).map(|t| {
                let latest = match &t.latest_event {
                    TimelineDetails::Ready(ev) => Some(ev),
                    _ => None,
                };
                ThreadSummary {
                    reply_count: t.num_replies,
                    latest_sender_name: latest.and_then(|ev| profile_name(&ev.sender_profile)),
                    latest_text: latest.map(|ev| content_text(&ev.content)),
                    latest_timestamp_ms: latest.map(|ev| millis(ev.timestamp)),
                }
            }),
            m.thread_root.as_ref().map(|id| id.to_string()),
        ),
        _ => (None, None),
    };
    let (body, reactions, reply_to, is_edited) = match e.content() {
        TimelineItemContent::MsgLike(m) => {
            let own = e.is_own();
            let me = own.then(|| e.sender().to_owned());
            let reactions = m
                .reactions
                .iter()
                .map(|(key, senders)| Reaction {
                    key: key.clone(),
                    count: senders.len() as u32,
                    by_me: senders.keys().any(|u| Some(u) == me.as_ref())
                        || senders.values().any(|r| r.send_state.is_some()),
                })
                .collect();
            let reply_to = m.in_reply_to.as_ref().map(|r| {
                let (sender_name, text) = match &r.event {
                    TimelineDetails::Ready(ev) => {
                        (profile_name(&ev.sender_profile), Some(content_text(&ev.content)))
                    }
                    _ => (None, None),
                };
                ReplyPreview { event_id: r.event_id.to_string(), sender_name, text }
            });
            // Bridges flag their own behind-the-scenes edits (a reel's still
            // swapped for the video, say) as not worth an "edited" mark.
            let quiet_edit = e
                .latest_json()
                .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw.json().get()).ok())
                .is_some_and(|v| v["content"]["com.beeper.dont_render_edited"] == true);
            let edited = !quiet_edit && matches!(&m.kind, MsgLikeKind::Message(msg) if msg.is_edited());
            let body = match &m.kind {
                MsgLikeKind::Other(o) if o.event_type().to_string() == SEND_STATUS_TYPE => e
                    .original_json()
                    .and_then(|raw| send_status(raw.json().get()))
                    .unwrap_or_else(|| msg_like_body(&m.kind, None)),
                kind => msg_like_body(kind, e.original_json().map(|raw| raw.json().get())),
            };
            (body, reactions, reply_to, edited)
        }
        other => (EventBody::State { text: content_text(other) }, vec![], None, false),
    };

    let send_state = match e.send_state() {
        None | Some(EventSendState::Sent { .. }) => SendState::Sent,
        Some(EventSendState::NotSentYet { .. }) => SendState::Sending,
        Some(EventSendState::SendingFailed { error, is_recoverable }) => SendState::Failed {
            error: error.to_string(),
            recoverable: *is_recoverable,
        },
    };

    let latest = e.latest_json().and_then(|raw| latest_content(raw.json().get()));

    let read_by = e
        .read_receipts()
        .keys()
        .filter(|u| u.as_str() != e.sender().as_str())
        .map(|u| u.to_string())
        .collect();

    EventItem {
        event_id: e.event_id().map(|id| id.to_string()),
        transaction_id: e.transaction_id().map(|id| id.to_string()),
        can_reply: e.can_be_replied_to(),
        can_edit: e.is_editable(),
        sender: e.sender().to_string(),
        sender_name: profile_name(e.sender_profile()),
        sender_avatar_mxc: profile_avatar(e.sender_profile()),
        is_own: e.is_own(),
        timestamp_ms: millis(e.timestamp()),
        body,
        send_state,
        reactions,
        reply_to,
        is_edited,
        read_by,
        link_preview: e.latest_json().and_then(|raw| beeper_link_preview(raw.json().get())),
        unresolved_media: latest.as_ref().and_then(|c| c.get("com.beeper.unresolved_media")).map(|v| v.to_string()),
        external_url: latest.as_ref().and_then(|c| c["external_url"].as_str()).map(str::to_owned),
        thread,
        thread_root,
    }
}

/// The content as it stands now: an edit's `m.new_content`, else the
/// event's own.
fn latest_content(json: &str) -> Option<serde_json::Value> {
    let mut v: serde_json::Value = serde_json::from_str(json).ok()?;
    let mut content = v.get_mut("content")?.take();
    match content.get_mut("m.new_content") {
        Some(new) => Some(new.take()),
        None => Some(content),
    }
}

/// The first `com.beeper.linkpreviews` entry, or for an edit, the one in
/// `m.new_content`.
fn beeper_link_preview(json: &str) -> Option<LinkPreview> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let content = v["content"].get("m.new_content").unwrap_or(&v["content"]);
    let p = content["com.beeper.linkpreviews"].as_array()?.first()?;
    let url = p["matched_url"].as_str().or_else(|| p["og:url"].as_str())?.to_owned();
    og_preview(url, p)
}

/// Reads Open Graph keys, as bridges and Synapse both use them.
pub(crate) fn og_preview(url: String, og: &serde_json::Value) -> Option<LinkPreview> {
    let text = |k: &str| og[k].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned);
    let preview = LinkPreview {
        url,
        title: text("og:title"),
        description: text("og:description"),
        site_name: text("og:site_name"),
        image_mxc: text("og:image").filter(|i| i.starts_with("mxc://")),
    };
    (preview.title.is_some() || preview.description.is_some()).then_some(preview)
}

/// MSC3245: voice notes carry `org.matrix.msc3245.voice` in their content.
fn is_voice(json: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .is_some_and(|v| v["content"].get("org.matrix.msc3245.voice").is_some())
}

fn msg_like_body(kind: &MsgLikeKind, raw_json: Option<&str>) -> EventBody {
    use matrix_sdk::ruma::events::room::MediaSource;
    let mxc = |s: &MediaSource| match s {
        MediaSource::Plain(u) => Some(u.to_string()),
        MediaSource::Encrypted(f) => Some(f.url.to_string()),
    };
    match kind {
        MsgLikeKind::Message(msg) => match msg.msgtype() {
            MessageType::Text(t) => EventBody::Text {
                body: t.body.clone(),
                formatted_html: t.formatted.as_ref().map(|f| f.body.clone()),
            },
            MessageType::Notice(n) => EventBody::Notice { body: n.body.clone() },
            MessageType::Emote(e) => EventBody::Emote { body: e.body.clone() },
            MessageType::Image(i) => EventBody::Image {
                body: i.body.clone(),
                mxc: mxc(&i.source),
                width: i.info.as_ref().and_then(|i| i.width).and_then(|w| u32::try_from(w).ok()),
                height: i.info.as_ref().and_then(|i| i.height).and_then(|h| u32::try_from(h).ok()),
            },
            MessageType::Video(v) => {
                let info = v.info.as_deref();
                EventBody::Video {
                    body: v.filename.clone().unwrap_or_else(|| v.body.clone()),
                    mxc: mxc(&v.source),
                    mimetype: info.and_then(|i| i.mimetype.clone()),
                    size: info.and_then(|i| i.size).map(|s| i64::from(s)),
                    duration_ms: info.and_then(|i| i.duration).map(|d| d.as_millis() as i64),
                    width: info.and_then(|i| i.width).and_then(|w| u32::try_from(w).ok()),
                    height: info.and_then(|i| i.height).and_then(|h| u32::try_from(h).ok()),
                    thumbnail_mxc: info.and_then(|i| i.thumbnail_source.as_ref()).and_then(mxc),
                }
            }
            MessageType::Audio(a) => {
                let info = a.info.as_deref();
                EventBody::Audio {
                    body: a.filename.clone().unwrap_or_else(|| a.body.clone()),
                    mxc: mxc(&a.source),
                    mimetype: info.and_then(|i| i.mimetype.clone()),
                    size: info.and_then(|i| i.size).map(|s| i64::from(s)),
                    duration_ms: info.and_then(|i| i.duration).map(|d| d.as_millis() as i64),
                    is_voice: raw_json.is_some_and(is_voice),
                }
            }
            MessageType::File(f) => {
                let info = f.info.as_deref();
                EventBody::File {
                    name: f.filename.clone().unwrap_or_else(|| f.body.clone()),
                    mxc: mxc(&f.source),
                    mimetype: info.and_then(|i| i.mimetype.clone()),
                    size: info.and_then(|i| i.size).map(|s| i64::from(s)),
                }
            }
            MessageType::Location(l) => EventBody::Location { body: l.body.clone() },
            other => EventBody::Unsupported { description: other.body().to_owned() },
        },
        MsgLikeKind::Sticker(s) => EventBody::Sticker {
            body: s.content().body.clone(),
            mxc: match &s.content().source {
                matrix_sdk::ruma::events::sticker::StickerMediaSource::Plain(u) => Some(u.to_string()),
                matrix_sdk::ruma::events::sticker::StickerMediaSource::Encrypted(f) => Some(f.url.to_string()),
                _ => None,
            },
        },
        MsgLikeKind::Poll(p) => EventBody::Poll { question: p.fallback_text().unwrap_or_default() },
        MsgLikeKind::Redacted => EventBody::Redacted,
        MsgLikeKind::UnableToDecrypt(_) => EventBody::Encrypted,
        MsgLikeKind::Other(o) => EventBody::Unsupported { description: o.event_type().to_string() },
        MsgLikeKind::LiveLocation(_) => EventBody::Location { body: "Live location".to_owned() },
    }
}

#[cfg(test)]
pub(crate) fn timeline_item_kind_for_test(e: &EventTimelineItem) -> TimelineItemKind {
    TimelineItemKind::Event(event_item(e))
}

pub(crate) const SEND_STATUS_TYPE: &str = "com.beeper.message_send_status";

/// Reads a `com.beeper.message_send_status` event. Shows the bridge's
/// `message`, never `error`, which mautrix keeps for bug reports.
pub(crate) fn send_status(json: &str) -> Option<EventBody> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let c = &v["content"];
    let for_event_id = c["m.relates_to"]["event_id"].as_str()?.to_owned();
    let status = match c["status"].as_str()? {
        "SUCCESS" => BridgeStatus::Delivered,
        "PENDING" => BridgeStatus::Pending,
        "FAIL_RETRIABLE" => BridgeStatus::Retriable,
        "FAIL_PERMANENT" => BridgeStatus::Failed,
        _ => return None,
    };
    let message = c["message"].as_str().filter(|m| !m.is_empty()).map(str::to_owned);
    Some(EventBody::SendStatus { for_event_id, status, message })
}

/// Reads `com.beeper.room_features` state content.
pub(crate) fn room_features(json: &str) -> Option<crate::api::types::RoomFeatures> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let c = v.get("content").unwrap_or(&v);
    let level = |k: &str| c[k].as_i64().unwrap_or(0) as i32;
    let flag = |k: &str| c[k].as_bool().unwrap_or(false);
    Some(crate::api::types::RoomFeatures {
        reply: level("reply"),
        thread: level("thread"),
        edit: level("edit"),
        delete: level("delete"),
        reaction: level("reaction"),
        allowed_reactions: c["allowed_reactions"]
            .as_array()
            .map(|a| a.iter().filter_map(|r| r.as_str().map(str::to_owned)).collect())
            .unwrap_or_default(),
        max_text_length: c["max_text_length"].as_u64().and_then(|n| u32::try_from(n).ok()),
        images: c["file"].get("m.image").is_some(),
        video: c["file"].get("m.video").is_some(),
        audio: c["file"].get("m.audio").is_some(),
        voice: c["file"].get("org.matrix.msc3245.voice").is_some(),
        files: c["file"].get("m.file").is_some(),
        typing_notifications: flag("typing_notifications"),
        read_receipts: flag("read_receipts"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_send_status() {
        let json = r#"{"type":"com.beeper.message_send_status","content":{"network":"whatsapp","m.relates_to":{"rel_type":"m.reference","event_id":"$abc"},"status":"FAIL_RETRIABLE","reason":"m.foreign_network_error","error":"internal detail","message":"Your message wasn't delivered"}}"#;
        match send_status(json) {
            Some(EventBody::SendStatus { for_event_id, status, message }) => {
                assert_eq!(for_event_id, "$abc");
                assert_eq!(status, BridgeStatus::Retriable);
                assert_eq!(message.as_deref(), Some("Your message wasn't delivered"));
            }
            other => panic!("{other:?}"),
        }
        assert!(send_status(r#"{"content":{"status":"WHAT"}}"#).is_none());
    }

    #[test]
    fn reads_beeper_link_previews() {
        let json = r#"{"content":{"body":"look https://example.com/x","com.beeper.linkpreviews":[{"matched_url":"https://example.com/x","og:title":"Example","og:description":"An example page","og:image":"mxc://switchboard.internal/abc","og:site_name":"Example Site"}]}}"#;
        let p = beeper_link_preview(json).unwrap();
        assert_eq!(p.url, "https://example.com/x");
        assert_eq!(p.title.as_deref(), Some("Example"));
        assert_eq!(p.image_mxc.as_deref(), Some("mxc://switchboard.internal/abc"));
        assert!(beeper_link_preview(r#"{"content":{"body":"x"}}"#).is_none());
        // Nothing worth showing without a title or description.
        assert!(beeper_link_preview(r#"{"content":{"com.beeper.linkpreviews":[{"matched_url":"https://x.y"}]}}"#).is_none());
    }

    #[test]
    fn reads_unresolved_media_until_an_edit_resolves_it() {
        let reel = r#"{"content":{"msgtype":"m.image","body":"reel","external_url":"https://www.instagram.com/reel/X/","com.beeper.unresolved_media":{"kind":"permanent"}}}"#;
        let c = latest_content(reel).unwrap();
        assert_eq!(c["com.beeper.unresolved_media"]["kind"], "permanent");
        assert_eq!(c["external_url"], "https://www.instagram.com/reel/X/");
        let edit = r#"{"content":{"msgtype":"m.video","body":"* reel","m.new_content":{"msgtype":"m.video","body":"reel","url":"mxc://a/b"},"com.beeper.unresolved_media":{"kind":"permanent"}}}"#;
        assert!(latest_content(edit).unwrap().get("com.beeper.unresolved_media").is_none());
    }

    #[test]
    fn reads_room_features() {
        let json = r#"{"type":"com.beeper.room_features","state_key":"","content":{"id":"fi.mau.signal.capabilities","reply":2,"edit":2,"delete":2,"reaction":2,"reaction_count":1,"allowed_reactions":["👍","❤️"],"max_text_length":65536,"file":{"m.image":{"mime_types":{"image/jpeg":2}},"org.matrix.msc3245.voice":{"mime_types":{"audio/ogg":2}}},"typing_notifications":true,"read_receipts":true}}"#;
        let f = room_features(json).unwrap();
        assert_eq!((f.reply, f.edit, f.delete, f.reaction), (2, 2, 2, 2));
        assert_eq!(f.allowed_reactions, vec!["👍", "❤️"]);
        assert_eq!(f.max_text_length, Some(65536));
        assert!(f.images && f.voice && f.typing_notifications && f.read_receipts);
        assert!(!f.video && !f.audio && !f.files);

        let bare = room_features(r#"{"content":{"edit":-2}}"#).unwrap();
        assert_eq!(bare.edit, -2);
        assert!(!bare.images);
    }
}
