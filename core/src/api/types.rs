//! Plain data passed to Dart. Every row is computed in Rust so the UI only
//! renders.

/// One row of the chat list.
#[derive(Clone, Debug)]
pub struct RoomSummary {
    pub id: String,
    pub name: String,
    pub avatar_mxc: Option<String>,
    /// The bridge network, from the room's `m.bridge` state.
    pub network: Option<Network>,
    pub is_dm: bool,
    /// For DMs, the other users, so the app can hide bridge bot chats.
    pub dm_user_ids: Vec<String>,
    /// Joined members, you included.
    pub member_count: u32,
    /// A few of the other members, from the server's room summary. With
    /// `member_count`, this tells a chat with yourself from the rest.
    pub hero_user_ids: Vec<String>,
    pub is_invite: bool,
    pub is_favourite: bool,
    /// The favourite tag's `order`, for the favourites' drag order.
    pub favourite_order: Option<f64>,
    pub is_low_priority: bool,
    pub is_marked_unread: bool,
    /// When the chat was archived (`app.switchboard.inbox.done`), in ms.
    /// It returns to the inbox when someone else writes after this.
    pub archived_at: Option<i64>,
    pub preview: Option<Preview>,
    /// Latest activity, in milliseconds since the epoch.
    pub timestamp_ms: Option<i64>,
    pub unread_count: u32,
    /// Unread messages, notifying or not: a Low Priority chat's are
    /// silent, so `unread_count` leaves them out.
    pub unread_messages: u32,
    pub mention_count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Network {
    /// Protocol ID as the bridge reports it, such as `whatsapp` or `signal`.
    pub id: String,
    pub name: String,
    pub avatar_mxc: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Preview {
    pub sender_name: Option<String>,
    pub is_own: bool,
    pub text: String,
    pub sending: bool,
    pub failed: bool,
    /// The latest event is a join, not a message: a chat the bridge made
    /// with no history sorts by when you joined, not by its last message.
    pub is_membership: bool,
}

/// Changes to the chat list, mirroring `eyeball_im::VectorDiff`.
#[derive(Clone, Debug)]
pub enum RoomListDiff {
    Append { values: Vec<RoomSummary> },
    Clear,
    PushFront { value: RoomSummary },
    PushBack { value: RoomSummary },
    PopFront,
    PopBack,
    Insert { index: u32, value: RoomSummary },
    Set { index: u32, value: RoomSummary },
    Remove { index: u32 },
    Truncate { length: u32 },
    Reset { values: Vec<RoomSummary> },
}

/// Changes to a timeline, mirroring `eyeball_im::VectorDiff`.
#[derive(Clone, Debug)]
pub enum TimelineDiff {
    Append { values: Vec<TimelineItem> },
    Clear,
    PushFront { value: TimelineItem },
    PushBack { value: TimelineItem },
    PopFront,
    PopBack,
    Insert { index: u32, value: TimelineItem },
    Set { index: u32, value: TimelineItem },
    Remove { index: u32 },
    Truncate { length: u32 },
    Reset { values: Vec<TimelineItem> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncStatus {
    Idle,
    Running,
    /// The server can't be reached; the SDK retries by itself.
    Offline,
    Error,
    Terminated,
}

#[derive(Clone, Debug)]
pub struct TimelineItem {
    /// Stable across updates of the same item.
    pub unique_id: String,
    pub kind: TimelineItemKind,
}

#[derive(Clone, Debug)]
pub enum TimelineItemKind {
    DateDivider { timestamp_ms: i64 },
    ReadMarker,
    TimelineStart,
    Event(EventItem),
}

#[derive(Clone, Debug)]
pub struct EventItem {
    pub event_id: Option<String>,
    /// Set while the event is a local echo; used to retry or cancel a send.
    pub transaction_id: Option<String>,
    pub can_reply: bool,
    pub can_edit: bool,
    pub sender: String,
    pub sender_name: Option<String>,
    pub sender_avatar_mxc: Option<String>,
    pub is_own: bool,
    pub timestamp_ms: i64,
    pub body: EventBody,
    pub send_state: SendState,
    pub reactions: Vec<Reaction>,
    pub reply_to: Option<ReplyPreview>,
    pub is_edited: bool,
    /// Users other than the sender whose read receipt is on this event.
    pub read_by: Vec<String>,
    /// The preview a bridge attached (`com.beeper.linkpreviews`), if any.
    pub link_preview: Option<LinkPreview>,
    /// `com.beeper.unresolved_media` as JSON: the bridge sent a stand-in
    /// (an Instagram reel's still, say) and can fetch the real media on
    /// request, replacing the message with it.
    pub unresolved_media: Option<String>,
    /// The original on the network, such as the reel's page.
    pub external_url: Option<String>,
}

/// A link's Open Graph preview, from the bridge or from Synapse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkPreview {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_name: Option<String>,
    pub image_mxc: Option<String>,
}

#[derive(Clone, Debug)]
pub enum EventBody {
    Text { body: String, formatted_html: Option<String> },
    Notice { body: String },
    Emote { body: String },
    Image { body: String, mxc: Option<String>, width: Option<u32>, height: Option<u32> },
    Video {
        body: String,
        mxc: Option<String>,
        mimetype: Option<String>,
        size: Option<i64>,
        duration_ms: Option<i64>,
        width: Option<u32>,
        height: Option<u32>,
        thumbnail_mxc: Option<String>,
    },
    /// Audio, or a voice note when `is_voice` (MSC3245).
    Audio { body: String, mxc: Option<String>, mimetype: Option<String>, size: Option<i64>, duration_ms: Option<i64>, is_voice: bool },
    File { name: String, mxc: Option<String>, mimetype: Option<String>, size: Option<i64> },
    Location { body: String },
    Sticker { body: String, mxc: Option<String> },
    Poll { question: String },
    Redacted,
    Encrypted,
    /// Membership, profile and other state changes, already worded.
    State { text: String },
    /// A bridge's `com.beeper.message_send_status` about one of our
    /// messages. Not shown itself; the app applies it to that message.
    SendStatus { for_event_id: String, status: BridgeStatus, message: Option<String> },
    Unsupported { description: String },
}

/// Whether the bridge delivered a message to the remote network.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BridgeStatus {
    Delivered,
    Pending,
    /// The bridge will retry, or the user may.
    Retriable,
    Failed,
}

/// What a bridged room's network can do, from `com.beeper.room_features`.
/// Levels follow mautrix: 2 full, 1 partial, 0 or below not supported.
#[derive(Clone, Debug)]
pub struct RoomFeatures {
    pub reply: i32,
    pub edit: i32,
    pub delete: i32,
    pub reaction: i32,
    /// Empty means any emoji.
    pub allowed_reactions: Vec<String>,
    pub max_text_length: Option<u32>,
    pub images: bool,
    pub video: bool,
    pub audio: bool,
    /// Voice notes (MSC3245).
    pub voice: bool,
    pub files: bool,
    pub typing_notifications: bool,
    pub read_receipts: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SendState {
    /// A remote event, or a local echo the server has accepted.
    Sent,
    Sending,
    Failed { error: String, recoverable: bool },
}

#[derive(Clone, Debug)]
pub struct Reaction {
    pub key: String,
    pub count: u32,
    pub by_me: bool,
}

#[derive(Clone, Debug)]
pub struct ReplyPreview {
    pub event_id: String,
    pub sender_name: Option<String>,
    pub text: Option<String>,
}

/// A room member, for typing indicators, "Seen" avatars and mentions.
#[derive(Clone, Debug)]
pub struct Member {
    pub user_id: String,
    pub name: Option<String>,
    pub avatar_mxc: Option<String>,
}

/// A raw Hub response. Dart decodes the JSON.
#[derive(Clone, Debug)]
pub struct HubResponse {
    pub status: u16,
    pub body: String,
}

/// What kind of message a search hit or media page entry is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MessageKind {
    Text,
    Image,
    Video,
    Audio,
    File,
}

/// A message from the search index: a search hit, or an entry on a chat's
/// media page.
#[derive(Clone, Debug)]
pub struct IndexedMessage {
    pub event_id: String,
    pub room_id: String,
    pub sender: String,
    pub sender_name: Option<String>,
    pub is_own: bool,
    pub timestamp_ms: i64,
    pub kind: MessageKind,
    /// The message's text, a media caption, or else the file name.
    pub text: String,
    /// The file name, for media.
    pub name: Option<String>,
    pub mxc: Option<String>,
    pub thumbnail_mxc: Option<String>,
    pub mimetype: Option<String>,
    pub size: Option<i64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<i64>,
    /// On the Links tab, the link.
    pub url: Option<String>,
}

#[derive(Clone, Debug)]
pub struct SearchHit {
    pub message: IndexedMessage,
    /// The text around the match, with each matched word between U+E000
    /// and U+E001.
    pub snippet: String,
}

/// A page of the server's search results.
#[derive(Clone, Debug)]
pub struct SearchPage {
    pub hits: Vec<SearchHit>,
    /// Where the next page starts; None at the end.
    pub next: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MediaTab {
    /// Photos and videos.
    Media,
    /// Files and audio.
    Files,
    Links,
}

#[derive(Clone, Debug)]
pub struct MediaPage {
    pub items: Vec<IndexedMessage>,
    /// Where the next page starts; None at the end.
    pub next: Option<String>,
}

/// How the search index stands.
#[derive(Clone, Debug, PartialEq)]
pub struct IndexStatus {
    /// How many days back it indexes; 0 for everything.
    pub period_days: u32,
    /// The oldest time it covers, in ms; None for everything.
    pub since_ms: Option<i64>,
    pub chats: u32,
    /// Chats indexed as far back as the period goes.
    pub chats_done: u32,
    pub messages: u32,
    /// Its size on disk.
    pub bytes: i64,
    pub indexing: bool,
    /// Why the last attempt failed, while it's retrying.
    pub error: Option<String>,
}
