//! The on-device search index: message text, media and links from every
//! chat, in SQLite with FTS5, for the period the user picks (a year unless
//! they change it).
//!
//! The indexer fills it from the server. A chat is first caught up from its
//! newest event back to the newest one already indexed, then filled back a
//! page at a time to the start of the period. Catching up comes before
//! filling back, so new messages are searchable first. Each sync that brings
//! a chat events queues it to be caught up again. Edits replace the text
//! they edit and unsends delete it.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use indexmap::IndexSet;
use matrix_sdk::{
    deserialized_responses::TimelineEvent,
    room::{Messages, MessagesOptions},
    ruma::{
        api::client::{
            filter::UrlFilter,
            search::search_events::v3::{Categories, Criteria, OrderBy, Request as SearchRequest},
        },
        OwnedRoomId, OwnedUserId, RoomId, UInt, UserId,
    },
    Client, Room, RoomState,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use tokio::sync::{broadcast, watch, Mutex, Notify};

use crate::{
    api::types::{IndexStatus, IndexedMessage, MediaTab, MessageKind},
    runtime,
};

/// The period indexed when the user hasn't picked one.
pub(crate) const DEFAULT_PERIOD_DAYS: u32 = 365;

/// Events asked for per page of history.
const PAGE: u32 = 200;

/// Marks the matched words in a snippet: private-use characters, so they
/// can't clash with message text.
pub(crate) const MARK_START: char = '\u{E000}';
pub(crate) const MARK_END: char = '\u{E001}';

const KIND_TEXT: i64 = 0;
const KIND_IMAGE: i64 = 1;
const KIND_VIDEO: i64 = 2;
const KIND_AUDIO: i64 = 3;
const KIND_FILE: i64 = 4;

pub(crate) fn path_in(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("search.sqlite3")
}

/// Deletes the index and its journal files.
pub(crate) fn remove_files(path: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let mut p = path.as_os_str().to_owned();
        p.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(p));
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Reading events

/// One indexed message.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Row {
    pub event_id: String,
    pub room_id: String,
    pub sender: String,
    pub sender_name: Option<String>,
    pub ts: i64,
    pub kind: i64,
    /// What search looks in: the text, a caption, or the file name.
    pub body: String,
    /// The file name, for media.
    pub name: Option<String>,
    pub mxc: Option<String>,
    pub thumbnail_mxc: Option<String>,
    pub mimetype: Option<String>,
    pub size: Option<i64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub duration_ms: Option<i64>,
}

/// What an event means for the index.
#[derive(Debug, PartialEq)]
pub(crate) enum Parsed {
    Message(Row),
    /// An edit: `body` replaces the original's text.
    Edit { original: String, sender: String, ts: i64, body: String },
    /// An unsend.
    Redaction { target: String },
    Skip,
}

/// Reads an event as JSON. `room_id` is used when the event doesn't carry
/// its own (sync and `/messages` events don't).
pub(crate) fn parse(room_id: &str, ev: &Value) -> Parsed {
    let str_field = |k: &str| ev.get(k).and_then(Value::as_str);
    let (Some(kind), Some(event_id), Some(sender)) = (str_field("type"), str_field("event_id"), str_field("sender"))
    else {
        return Parsed::Skip;
    };
    if ev.get("state_key").is_some() {
        return Parsed::Skip;
    }
    let ts = ev.get("origin_server_ts").and_then(Value::as_i64).unwrap_or_default();
    let Some(content) = ev.get("content").filter(|c| c.is_object()) else {
        return Parsed::Skip;
    };
    match kind {
        "m.room.redaction" => {
            // Room v11 moved `redacts` into the content.
            match content.get("redacts").or_else(|| ev.get("redacts")).and_then(Value::as_str) {
                Some(target) => Parsed::Redaction { target: target.to_owned() },
                None => Parsed::Skip,
            }
        }
        "m.room.message" => {
            let relation = content.get("m.relates_to");
            if relation.and_then(|r| r.get("rel_type")).and_then(Value::as_str) == Some("m.replace") {
                let original = relation.and_then(|r| r.get("event_id")).and_then(Value::as_str);
                let new = content.get("m.new_content");
                let body = new
                    .and_then(content_row)
                    .map(|r| r.body)
                    .or_else(|| new.and_then(|n| n.get("body")).and_then(Value::as_str).map(str::to_owned));
                return match (original, body) {
                    (Some(original), Some(body)) => Parsed::Edit {
                        original: original.to_owned(),
                        sender: sender.to_owned(),
                        ts,
                        body,
                    },
                    _ => Parsed::Skip,
                };
            }
            match content_row(content) {
                Some(row) => Parsed::Message(Row {
                    event_id: event_id.to_owned(),
                    room_id: str_field("room_id").unwrap_or(room_id).to_owned(),
                    sender: sender.to_owned(),
                    ts,
                    ..row
                }),
                None => Parsed::Skip,
            }
        }
        _ => Parsed::Skip,
    }
}

/// The searchable part of a message's content. Voice notes, locations and
/// encrypted attachments (which the app can't show) are left out.
fn content_row(content: &Value) -> Option<Row> {
    let msgtype = content.get("msgtype")?.as_str()?;
    let body = content.get("body").and_then(Value::as_str).unwrap_or_default();
    let kind = match msgtype {
        "m.image" => KIND_IMAGE,
        "m.video" => KIND_VIDEO,
        "m.audio" => KIND_AUDIO,
        "m.file" => KIND_FILE,
        "m.location" | "m.key.verification.request" => return None,
        _ => {
            let text = strip_reply_fallback(content, body);
            return (!text.trim().is_empty()).then(|| Row { kind: KIND_TEXT, body: text.to_owned(), ..Row::default() });
        }
    };
    if kind == KIND_AUDIO && (content.get("org.matrix.msc3245.voice").is_some() || content.get("voice").is_some()) {
        return None;
    }
    let mxc = content.get("url")?.as_str()?;
    // With a `filename` that differs, the body is a caption (MSC2530).
    let filename = content.get("filename").and_then(Value::as_str).filter(|f| !f.is_empty());
    let (name, caption) = match filename {
        Some(f) if f != body => (f, body),
        _ => (body, ""),
    };
    let info = content.get("info");
    let info_str = |k: &str| info.and_then(|i| i.get(k)).and_then(Value::as_str).map(str::to_owned);
    let info_int = |k: &str| info.and_then(|i| i.get(k)).and_then(Value::as_i64);
    Some(Row {
        kind,
        body: if caption.trim().is_empty() { name } else { caption }.to_owned(),
        name: Some(name.to_owned()),
        mxc: Some(mxc.to_owned()),
        thumbnail_mxc: info_str("thumbnail_url"),
        mimetype: info_str("mimetype"),
        size: info_int("size"),
        width: info_int("w"),
        height: info_int("h"),
        duration_ms: info_int("duration"),
        ..Row::default()
    })
}

/// A reply's text without the quoted fallback some clients still prepend.
fn strip_reply_fallback<'a>(content: &Value, body: &'a str) -> &'a str {
    let is_reply = content.pointer("/m.relates_to/m.in_reply_to").is_some();
    if is_reply && body.starts_with("> ") {
        if let Some(at) = body.find("\n\n") {
            return &body[at + 2..];
        }
    }
    body
}

/// The http(s) links in a message's text.
pub(crate) fn links(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for word in text.split_whitespace() {
        let Some(start) = word.find("https://").or_else(|| word.find("http://")) else { continue };
        let url = word[start..].trim_end_matches(['.', ',', ';', ':', '!', '?', ')', ']', '}', '>', '"', '\'']);
        // Something past the scheme.
        if url.split_once("://").is_some_and(|(_, rest)| rest.len() > 1) && !out.iter().any(|u| u == url) {
            out.push(url.to_owned());
        }
        if out.len() == 10 {
            break;
        }
    }
    out
}

/// The words of a query as an FTS5 expression: each one quoted and matched
/// as a prefix, all of them required. None when nothing searchable is left.
pub(crate) fn fts_query(text: &str) -> Option<String> {
    let terms: Vec<String> = text
        .split_whitespace()
        .map(|w| w.replace('"', ""))
        .filter(|w| w.chars().any(char::is_alphanumeric))
        .map(|w| format!("\"{w}\"*"))
        .collect();
    (!terms.is_empty()).then(|| terms.join(" "))
}

/// Marks where words of `query` start a word in `text`, case-insensitively,
/// and keeps about `max` characters around the first match. For the
/// server's results, which come without FTS5's snippets.
pub(crate) fn highlight(text: &str, query: &str, max: usize) -> String {
    let terms: Vec<String> = query
        .split_whitespace()
        .map(|w| w.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase())
        .filter(|w| !w.is_empty())
        .collect();
    let chars: Vec<char> = text.chars().collect();
    let lower: Vec<char> = text.chars().map(|c| c.to_lowercase().next().unwrap_or(c)).collect();
    // (start, end) in chars.
    let mut marks: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i < lower.len() {
        let word_start = i == 0 || !lower[i - 1].is_alphanumeric();
        if word_start && lower[i].is_alphanumeric() {
            let hit = terms.iter().filter_map(|t| {
                let t: Vec<char> = t.chars().collect();
                (lower.len() >= i + t.len() && lower[i..i + t.len()] == t[..]).then_some(t.len())
            });
            if let Some(len) = hit.max() {
                marks.push((i, i + len));
                i += len;
                continue;
            }
        }
        i += 1;
    }
    let (from, to) = match marks.first() {
        _ if chars.len() <= max => (0, chars.len()),
        Some(&(s, _)) => {
            let from = s.saturating_sub(max / 4);
            (from, (from + max).min(chars.len()))
        }
        None => (0, max),
    };
    let mut out = String::new();
    if from > 0 {
        out.push('…');
    }
    for (idx, c) in chars.iter().enumerate().take(to).skip(from) {
        if marks.iter().any(|&(s, _)| s == idx) {
            out.push(MARK_START);
        }
        out.push(*c);
        if marks.iter().any(|&(_, e)| e == idx + 1) {
            out.push(MARK_END);
        }
    }
    // A mark cut off by the end.
    if out.chars().filter(|&c| c == MARK_START).count() > out.chars().filter(|&c| c == MARK_END).count() {
        out.push(MARK_END);
    }
    if to < chars.len() {
        out.push('…');
    }
    out
}

// ---------------------------------------------------------------------------
// The database

/// How far a chat is indexed.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Progress {
    /// The newest event seen at the chat's end, where catching up stops.
    pub newest_event: Option<String>,
    /// Where filling back continues.
    pub back_token: Option<String>,
    /// The oldest event's time reached so far.
    pub oldest_ts: Option<i64>,
    /// The start of the chat was reached.
    pub complete: bool,
}

impl Progress {
    fn needs_backfill(&self, since: Option<i64>) -> bool {
        !self.complete && since.is_none_or(|since| self.oldest_ts.is_none_or(|t| t >= since))
    }
}

pub(crate) struct Query<'a> {
    pub text: &'a str,
    pub room_id: Option<&'a str>,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub offset: u32,
    pub limit: u32,
}

/// Where a media page starts: before a message in the index, or at a token
/// in the server's history once the index has nothing older.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Cursor {
    Index { ts: i64, event_id: String, url: String },
    /// `None` starts at the chat's newest event.
    Server(Option<String>),
}

impl Cursor {
    pub(crate) fn encode(&self) -> String {
        match self {
            Cursor::Index { ts, event_id, url } => format!("i|{ts}|{event_id}|{url}"),
            Cursor::Server(token) => format!("s|{}", token.as_deref().unwrap_or_default()),
        }
    }

    pub(crate) fn decode(s: &str) -> Option<Cursor> {
        let mut parts = s.splitn(4, '|');
        match parts.next()? {
            "i" => Some(Cursor::Index {
                ts: parts.next()?.parse().ok()?,
                event_id: parts.next()?.to_owned(),
                url: parts.next().unwrap_or_default().to_owned(),
            }),
            "s" => Some(Cursor::Server(parts.next().filter(|t| !t.is_empty()).map(str::to_owned))),
            _ => None,
        }
    }
}

pub(crate) struct Db {
    conn: StdMutex<Connection>,
    path: Option<PathBuf>,
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS rooms (
    room_id TEXT PRIMARY KEY,
    newest_event TEXT,
    back_token TEXT,
    oldest_ts INTEGER,
    complete INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL UNIQUE,
    room_id TEXT NOT NULL,
    sender TEXT NOT NULL,
    sender_name TEXT,
    ts INTEGER NOT NULL,
    kind INTEGER NOT NULL,
    body TEXT NOT NULL,
    edited_ts INTEGER,
    name TEXT,
    mxc TEXT,
    thumbnail_mxc TEXT,
    mimetype TEXT,
    size INTEGER,
    width INTEGER,
    height INTEGER,
    duration_ms INTEGER
);
CREATE INDEX IF NOT EXISTS messages_ts ON messages (ts);
CREATE INDEX IF NOT EXISTS messages_room_kind_ts ON messages (room_id, kind, ts);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5 (
    body, content = 'messages', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts (rowid, body) VALUES (new.id, new.body);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts (messages_fts, rowid, body) VALUES ('delete', old.id, old.body);
    DELETE FROM links WHERE event_id = old.event_id;
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF body ON messages BEGIN
    INSERT INTO messages_fts (messages_fts, rowid, body) VALUES ('delete', old.id, old.body);
    INSERT INTO messages_fts (rowid, body) VALUES (new.id, new.body);
END;
CREATE TABLE IF NOT EXISTS links (
    event_id TEXT NOT NULL,
    room_id TEXT NOT NULL,
    ts INTEGER NOT NULL,
    url TEXT NOT NULL,
    PRIMARY KEY (event_id, url)
);
CREATE INDEX IF NOT EXISTS links_room_ts ON links (room_id, ts);
-- Edits seen before the message they edit: paging back, the edit comes first.
CREATE TABLE IF NOT EXISTS pending_edits (
    original TEXT PRIMARY KEY,
    sender TEXT NOT NULL,
    ts INTEGER NOT NULL,
    body TEXT NOT NULL
);
"#;

const ROW_COLUMNS: &str = "m.event_id, m.room_id, m.sender, m.sender_name, m.ts, m.kind, m.body, m.name, m.mxc, \
     m.thumbnail_mxc, m.mimetype, m.size, m.width, m.height, m.duration_ms";

fn read_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Row> {
    Ok(Row {
        event_id: r.get(0)?,
        room_id: r.get(1)?,
        sender: r.get(2)?,
        sender_name: r.get(3)?,
        ts: r.get(4)?,
        kind: r.get(5)?,
        body: r.get(6)?,
        name: r.get(7)?,
        mxc: r.get(8)?,
        thumbnail_mxc: r.get(9)?,
        mimetype: r.get(10)?,
        size: r.get(11)?,
        width: r.get(12)?,
        height: r.get(13)?,
        duration_ms: r.get(14)?,
    })
}

impl Db {
    pub(crate) fn open(path: &Path) -> Result<Db> {
        let conn = Connection::open(path).with_context(|| format!("can't open {}", path.display()))?;
        Self::init(conn, Some(path.to_owned()))
    }

    pub(crate) fn open_in_memory() -> Result<Db> {
        Self::init(Connection::open_in_memory()?, None)
    }

    fn init(conn: Connection, path: Option<PathBuf>) -> Result<Db> {
        // Space freed by pruning goes back to the system. Only takes effect
        // before the first table is made.
        conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Db { conn: StdMutex::new(conn), path })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(crate) fn period_days(&self) -> u32 {
        self.lock()
            .query_row("SELECT value FROM meta WHERE key = 'period_days'", [], |r| r.get::<_, String>(0))
            .optional()
            .ok()
            .flatten()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_PERIOD_DAYS)
    }

    /// The oldest time indexed: `days` before `now`, or None for everything.
    pub(crate) fn since(&self, now: i64) -> Option<i64> {
        match self.period_days() {
            0 => None,
            days => Some(now - i64::from(days) * 86_400_000),
        }
    }

    /// Changes the period. A shorter one deletes what falls outside it; a
    /// longer one starts every chat again from its newest event, because
    /// what was pruned before left gaps. Returns whether it changed.
    pub(crate) fn set_period_days(&self, days: u32, now: i64) -> Result<bool> {
        let old = self.period_days();
        if old == days {
            return Ok(false);
        }
        let longer = days == 0 || (old != 0 && days > old);
        {
            let mut conn = self.lock();
            let tx = conn.transaction()?;
            tx.execute(
                "INSERT INTO meta (key, value) VALUES ('period_days', ?1)
                 ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                params![days.to_string()],
            )?;
            if longer {
                tx.execute("DELETE FROM rooms", [])?;
            }
            tx.commit()?;
        }
        if !longer {
            self.prune(now)?;
        }
        Ok(true)
    }

    /// Deletes messages older than the period. Returns how many went.
    pub(crate) fn prune(&self, now: i64) -> Result<usize> {
        let Some(since) = self.since(now) else { return Ok(0) };
        let conn = self.lock();
        let n = conn.execute("DELETE FROM messages WHERE ts < ?1", params![since])?;
        conn.execute("DELETE FROM pending_edits WHERE ts < ?1", params![since])?;
        if n > 0 {
            conn.execute("INSERT INTO messages_fts (messages_fts) VALUES ('optimize')", [])?;
            conn.execute_batch("PRAGMA incremental_vacuum;")?;
        }
        Ok(n)
    }

    pub(crate) fn progress(&self, room_id: &str) -> Result<Option<Progress>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT newest_event, back_token, oldest_ts, complete FROM rooms WHERE room_id = ?1",
                params![room_id],
                |r| {
                    Ok(Progress {
                        newest_event: r.get(0)?,
                        back_token: r.get(1)?,
                        oldest_ts: r.get(2)?,
                        complete: r.get::<_, i64>(3)? != 0,
                    })
                },
            )
            .optional()?)
    }

    /// Writes a page of events, oldest last as the server sends them, and
    /// the chat's new progress if given, in one transaction.
    pub(crate) fn write(&self, room_id: &str, events: &[Parsed], progress: Option<&Progress>) -> Result<()> {
        let mut conn = self.lock();
        let tx = conn.transaction()?;
        for ev in events {
            match ev {
                Parsed::Message(row) => {
                    let inserted = tx.execute(
                        "INSERT INTO messages (event_id, room_id, sender, sender_name, ts, kind, body, name, mxc,
                             thumbnail_mxc, mimetype, size, width, height, duration_ms)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                         ON CONFLICT (event_id) DO NOTHING",
                        params![
                            row.event_id,
                            row.room_id,
                            row.sender,
                            row.sender_name,
                            row.ts,
                            row.kind,
                            row.body,
                            row.name,
                            row.mxc,
                            row.thumbnail_mxc,
                            row.mimetype,
                            row.size,
                            row.width,
                            row.height,
                            row.duration_ms
                        ],
                    )?;
                    if inserted == 0 {
                        continue;
                    }
                    let pending: Option<(i64, String)> = tx
                        .query_row(
                            "DELETE FROM pending_edits WHERE original = ?1 AND sender = ?2 RETURNING ts, body",
                            params![row.event_id, row.sender],
                            |r| Ok((r.get(0)?, r.get(1)?)),
                        )
                        .optional()?;
                    let body = match pending {
                        Some((ts, body)) => {
                            tx.execute(
                                "UPDATE messages SET body = ?1, edited_ts = ?2 WHERE event_id = ?3",
                                params![body, ts, row.event_id],
                            )?;
                            body
                        }
                        None => row.body.clone(),
                    };
                    if row.kind == KIND_TEXT {
                        insert_links(&tx, &row.event_id, &row.room_id, row.ts, &body)?;
                    }
                }
                Parsed::Edit { original, sender, ts, body } => {
                    let found: Option<(i64, String, i64, Option<i64>)> = tx
                        .query_row(
                            "SELECT kind, sender, ts, edited_ts FROM messages WHERE event_id = ?1",
                            params![original],
                            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                        )
                        .optional()?;
                    match found {
                        // Only the sender can edit, and only a newer edit wins.
                        Some((kind, s, sent, edited)) if s == *sender && edited.is_none_or(|e| e < *ts) => {
                            tx.execute(
                                "UPDATE messages SET body = ?1, edited_ts = ?2 WHERE event_id = ?3",
                                params![body, ts, original],
                            )?;
                            if kind == KIND_TEXT {
                                tx.execute("DELETE FROM links WHERE event_id = ?1", params![original])?;
                                insert_links(&tx, original, room_id, sent, body)?;
                            }
                        }
                        Some(_) => {}
                        None => {
                            tx.execute(
                                "INSERT INTO pending_edits (original, sender, ts, body) VALUES (?1, ?2, ?3, ?4)
                                 ON CONFLICT (original) DO UPDATE SET sender = excluded.sender, ts = excluded.ts,
                                     body = excluded.body
                                 WHERE excluded.ts > pending_edits.ts",
                                params![original, sender, ts, body],
                            )?;
                        }
                    }
                }
                Parsed::Redaction { target } => {
                    tx.execute("DELETE FROM messages WHERE event_id = ?1", params![target])?;
                    tx.execute("DELETE FROM pending_edits WHERE original = ?1", params![target])?;
                }
                Parsed::Skip => {}
            }
        }
        if let Some(p) = progress {
            tx.execute(
                "INSERT INTO rooms (room_id, newest_event, back_token, oldest_ts, complete) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (room_id) DO UPDATE SET newest_event = excluded.newest_event,
                     back_token = excluded.back_token, oldest_ts = excluded.oldest_ts, complete = excluded.complete",
                params![room_id, p.newest_event, p.back_token, p.oldest_ts, p.complete as i64],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub(crate) fn set_newest(&self, room_id: &str, event_id: &str) -> Result<()> {
        self.lock()
            .execute("UPDATE rooms SET newest_event = ?1 WHERE room_id = ?2", params![event_id, room_id])?;
        Ok(())
    }

    /// Forgets chats the user is no longer in.
    pub(crate) fn retain_rooms(&self, joined: &HashSet<String>) -> Result<()> {
        let mut conn = self.lock();
        let tx = conn.transaction()?;
        let known: Vec<String> = {
            let mut stmt = tx.prepare("SELECT room_id FROM rooms UNION SELECT DISTINCT room_id FROM messages")?;
            stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
        };
        for room in known.iter().filter(|r| !joined.contains(*r)) {
            tx.execute("DELETE FROM messages WHERE room_id = ?1", params![room])?;
            tx.execute("DELETE FROM rooms WHERE room_id = ?1", params![room])?;
        }
        tx.commit()?;
        Ok(())
    }

    pub(crate) fn forget_room(&self, room_id: &str) -> Result<()> {
        let conn = self.lock();
        conn.execute("DELETE FROM messages WHERE room_id = ?1", params![room_id])?;
        conn.execute("DELETE FROM rooms WHERE room_id = ?1", params![room_id])?;
        Ok(())
    }

    /// Messages matching the query, newest first, with a snippet each.
    pub(crate) fn search(&self, q: &Query<'_>) -> Result<Vec<(Row, String)>> {
        let Some(fts) = fts_query(q.text) else { return Ok(Vec::new()) };
        let conn = self.lock();
        let sql = format!(
            // 14 words: about the two lines a result shows, match included.
            "SELECT {ROW_COLUMNS}, snippet(messages_fts, 0, ?7, ?8, '…', 14)
             FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
             WHERE messages_fts MATCH ?1 AND (?2 IS NULL OR m.room_id = ?2)
                 AND (?3 IS NULL OR m.ts >= ?3) AND (?4 IS NULL OR m.ts < ?4)
             ORDER BY m.ts DESC, m.id DESC LIMIT ?5 OFFSET ?6"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt.query_map(
            params![
                fts,
                q.room_id,
                q.since,
                q.until,
                q.limit,
                q.offset,
                MARK_START.to_string(),
                MARK_END.to_string()
            ],
            |r| Ok((read_row(r)?, r.get(15)?)),
        )?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// A chat's media, files or links, newest first, from before `cursor`.
    /// Links come with their URL.
    pub(crate) fn media(
        &self,
        room_id: &str,
        tab: &MediaTab,
        before: Option<(i64, &str, &str)>,
        limit: u32,
    ) -> Result<Vec<(Row, Option<String>)>> {
        let conn = self.lock();
        let (ts, event_id, url) = before.unwrap_or((i64::MAX, "", ""));
        if let MediaTab::Links = tab {
            let sql = format!(
                "SELECT {ROW_COLUMNS}, l.url FROM links l JOIN messages m ON m.event_id = l.event_id
                 WHERE l.room_id = ?1 AND (l.ts, l.event_id, l.url) < (?2, ?3, ?4)
                 ORDER BY l.ts DESC, l.event_id DESC, l.url DESC LIMIT ?5"
            );
            let mut stmt = conn.prepare_cached(&sql)?;
            let rows = stmt.query_map(params![room_id, ts, event_id, url, limit], |r| {
                Ok((read_row(r)?, Some(r.get::<_, String>(15)?)))
            })?;
            return Ok(rows.collect::<rusqlite::Result<_>>()?);
        }
        let (a, b) = match tab {
            MediaTab::Media => (KIND_IMAGE, KIND_VIDEO),
            _ => (KIND_AUDIO, KIND_FILE),
        };
        let sql = format!(
            "SELECT {ROW_COLUMNS} FROM messages m
             WHERE m.room_id = ?1 AND m.kind IN (?2, ?3) AND (m.ts, m.event_id) < (?4, ?5)
             ORDER BY m.ts DESC, m.event_id DESC LIMIT ?6"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt.query_map(params![room_id, a, b, ts, event_id, limit], |r| Ok((read_row(r)?, None)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Which of `event_ids` are indexed.
    pub(crate) fn contains(&self, event_ids: &[String]) -> Result<HashSet<String>> {
        let conn = self.lock();
        let mut stmt = conn.prepare_cached("SELECT 1 FROM messages WHERE event_id = ?1")?;
        let mut out = HashSet::new();
        for id in event_ids {
            if stmt.exists(params![id])? {
                out.insert(id.clone());
            }
        }
        Ok(out)
    }

    /// Messages indexed, and chats indexed as far back as the period goes.
    pub(crate) fn counts(&self, since: Option<i64>) -> Result<(u32, u32)> {
        let conn = self.lock();
        let messages: u32 = conn.query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0))?;
        let done: u32 = conn.query_row(
            "SELECT COUNT(*) FROM rooms WHERE complete = 1 OR (?1 IS NOT NULL AND oldest_ts < ?1)",
            params![since],
            |r| r.get(0),
        )?;
        Ok((messages, done))
    }

    /// The index's size on disk, journal included.
    pub(crate) fn bytes(&self) -> u64 {
        let Some(path) = &self.path else { return 0 };
        ["", "-wal"]
            .iter()
            .map(|suffix| {
                let mut p = path.as_os_str().to_owned();
                p.push(suffix);
                std::fs::metadata(PathBuf::from(p)).map(|m| m.len()).unwrap_or_default()
            })
            .sum()
    }

    /// Folds the journal into the database and empties it, so the size
    /// shown is what the index takes.
    pub(crate) fn checkpoint(&self) {
        if let Err(e) = self.lock().execute_batch("PRAGMA wal_checkpoint(TRUNCATE);") {
            tracing::info!("couldn't checkpoint the search index: {e}");
        }
    }

    pub(crate) fn clear(&self) -> Result<()> {
        self.lock().execute_batch(
            "DELETE FROM messages; DELETE FROM rooms; DELETE FROM links; DELETE FROM pending_edits;
             INSERT INTO messages_fts (messages_fts) VALUES ('optimize'); PRAGMA incremental_vacuum;",
        )?;
        Ok(())
    }
}

fn insert_links(tx: &rusqlite::Transaction<'_>, event_id: &str, room_id: &str, ts: i64, body: &str) -> Result<()> {
    for url in links(body) {
        tx.execute(
            "INSERT OR IGNORE INTO links (event_id, room_id, ts, url) VALUES (?1, ?2, ?3, ?4)",
            params![event_id, room_id, ts, url],
        )?;
    }
    Ok(())
}

pub(crate) fn message_kind(kind: i64) -> MessageKind {
    match kind {
        KIND_IMAGE => MessageKind::Image,
        KIND_VIDEO => MessageKind::Video,
        KIND_AUDIO => MessageKind::Audio,
        KIND_FILE => MessageKind::File,
        _ => MessageKind::Text,
    }
}

pub(crate) fn to_message(row: Row, own: &UserId, url: Option<String>) -> IndexedMessage {
    let dim = |v: Option<i64>| v.and_then(|v| u32::try_from(v).ok());
    IndexedMessage {
        is_own: row.sender == own.as_str(),
        kind: message_kind(row.kind),
        event_id: row.event_id,
        room_id: row.room_id,
        sender: row.sender,
        sender_name: row.sender_name,
        timestamp_ms: row.ts,
        text: row.body,
        name: row.name,
        mxc: row.mxc,
        thumbnail_mxc: row.thumbnail_mxc,
        mimetype: row.mimetype,
        size: row.size,
        width: dim(row.width),
        height: dim(row.height),
        duration_ms: row.duration_ms,
        url,
    }
}

// ---------------------------------------------------------------------------
// The indexer

#[derive(Debug)]
enum Job {
    CatchUp(OwnedRoomId),
    Backfill(OwnedRoomId),
}

#[derive(Default)]
struct Jobs {
    catch_up: IndexSet<OwnedRoomId>,
    backfill: VecDeque<OwnedRoomId>,
}

pub(crate) struct Indexer {
    pub(crate) db: Db,
    client: Client,
    jobs: StdMutex<Jobs>,
    wake: Notify,
    /// Held while a chat is being indexed, so two never write one chat.
    work: Mutex<()>,
    status: watch::Sender<IndexStatus>,
    last_status: StdMutex<Option<Instant>>,
    started: std::sync::Once,
    stopped: AtomicBool,
}

impl Indexer {
    pub(crate) fn new(client: Client, db: Db) -> Arc<Indexer> {
        let period_days = db.period_days();
        Arc::new(Indexer {
            db,
            client,
            jobs: StdMutex::new(Jobs::default()),
            wake: Notify::new(),
            work: Mutex::new(()),
            status: watch::channel(IndexStatus {
                period_days,
                since_ms: None,
                chats: 0,
                chats_done: 0,
                messages: 0,
                bytes: 0,
                indexing: false,
                error: None,
            })
            .0,
            last_status: StdMutex::new(None),
            started: std::sync::Once::new(),
            stopped: AtomicBool::new(false),
        })
    }

    /// Starts indexing, once. `updates` must be subscribed before the first
    /// sync so no chat's new events are missed.
    pub(crate) fn start(self: &Arc<Self>, updates: broadcast::Receiver<matrix_sdk::sync::RoomUpdates>) {
        self.started.call_once(|| {
            runtime::spawn(self.clone().watch(updates));
            runtime::spawn(self.clone().run());
        });
    }

    /// Stops indexing and empties the index, on sign-out.
    pub(crate) async fn shut_down(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.wake.notify_one();
        let _work = self.work.lock().await;
        if let Err(e) = self.db.clear() {
            tracing::warn!("couldn't empty the search index: {e:#}");
        }
    }

    pub(crate) fn subscribe(&self) -> watch::Receiver<IndexStatus> {
        self.status.subscribe()
    }

    /// Chats waiting to be caught up or filled back.
    #[cfg(test)]
    pub(crate) fn queued(&self) -> usize {
        let jobs = self.jobs.lock().unwrap();
        jobs.catch_up.len() + jobs.backfill.len()
    }

    pub(crate) fn status_now(&self) -> IndexStatus {
        let indexing = self.status.borrow().indexing;
        self.status(indexing, None)
    }

    pub(crate) async fn set_period(&self, days: u32) -> Result<()> {
        let changed = {
            let _work = self.work.lock().await;
            self.db.set_period_days(days, now_ms())?
        };
        if changed {
            self.queue_all();
        }
        // Not inside publish's call: the borrow would block its send.
        let indexing = self.status.borrow().indexing;
        self.publish(indexing, None, true);
        Ok(())
    }

    fn queue(&self, room_id: OwnedRoomId) {
        self.jobs.lock().unwrap().catch_up.insert(room_id);
        self.wake.notify_one();
    }

    /// Queues every joined chat, most recently active first, and forgets
    /// the ones left.
    fn queue_all(&self) {
        let mut rooms: Vec<Room> = self.client.joined_rooms().into_iter().filter(|r| !r.is_space()).collect();
        let joined: HashSet<String> = rooms.iter().map(|r| r.room_id().to_string()).collect();
        if let Err(e) = self.db.retain_rooms(&joined) {
            tracing::warn!("couldn't forget left chats in the search index: {e:#}");
        }
        rooms.sort_by_key(|r| std::cmp::Reverse(r.recency_stamp().map(u64::from).unwrap_or_default()));
        let mut jobs = self.jobs.lock().unwrap();
        for room in rooms {
            jobs.catch_up.insert(room.room_id().to_owned());
        }
        drop(jobs);
        self.wake.notify_one();
    }

    fn next_job(&self) -> Option<Job> {
        let mut jobs = self.jobs.lock().unwrap();
        if let Some(id) = jobs.catch_up.shift_remove_index(0) {
            return Some(Job::CatchUp(id));
        }
        jobs.backfill.pop_front().map(Job::Backfill)
    }

    async fn watch(self: Arc<Self>, mut updates: broadcast::Receiver<matrix_sdk::sync::RoomUpdates>) {
        loop {
            match updates.recv().await {
                Ok(update) => {
                    for (room_id, joined) in update.joined {
                        if !joined.timeline.events.is_empty() {
                            self.queue(room_id);
                        }
                    }
                    for room_id in update.left.keys() {
                        if let Err(e) = self.db.forget_room(room_id.as_str()) {
                            tracing::warn!(%room_id, "couldn't forget a left chat in the search index: {e:#}");
                        }
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => self.queue_all(),
                Err(broadcast::error::RecvError::Closed) => break,
            }
            if self.stopped.load(Ordering::SeqCst) {
                break;
            }
        }
    }

    async fn run(self: Arc<Self>) {
        if let Err(e) = self.db.prune(now_ms()) {
            tracing::warn!("couldn't prune the search index: {e:#}");
        }
        self.queue_all();
        let mut failures = 0u32;
        loop {
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            let Some(job) = self.next_job() else {
                self.db.checkpoint();
                self.publish(false, None, true);
                self.wake.notified().await;
                continue;
            };
            self.publish(true, None, false);
            let result = {
                let _work = self.work.lock().await;
                if self.stopped.load(Ordering::SeqCst) {
                    return;
                }
                match &job {
                    Job::CatchUp(id) => self.catch_up(id).await,
                    Job::Backfill(id) => self.backfill(id).await,
                }
            };
            match result {
                Ok(more) => {
                    failures = 0;
                    let id = match job {
                        Job::CatchUp(id) | Job::Backfill(id) => id,
                    };
                    let mut jobs = self.jobs.lock().unwrap();
                    if more && !jobs.backfill.contains(&id) {
                        jobs.backfill.push_back(id);
                    }
                }
                Err(e) => {
                    failures += 1;
                    tracing::info!(?job, "indexing failed: {e:#}");
                    {
                        let mut jobs = self.jobs.lock().unwrap();
                        match job {
                            Job::CatchUp(id) => {
                                jobs.catch_up.insert(id);
                            }
                            Job::Backfill(id) => jobs.backfill.push_front(id),
                        }
                    }
                    self.publish(true, Some(format!("{e:#}")), true);
                    // Offline, most likely: try again with backoff, sooner
                    // if a sync brings something.
                    let wait = Duration::from_secs(1 << failures.min(6));
                    let _ = tokio::time::timeout(wait, self.wake.notified()).await;
                }
            }
        }
    }

    fn joined(&self, room_id: &RoomId) -> Option<Room> {
        self.client.get_room(room_id).filter(|r| r.state() == RoomState::Joined && !r.is_space())
    }

    /// Brings a chat up to its newest event. Returns whether it still
    /// needs filling back.
    async fn catch_up(&self, room_id: &RoomId) -> Result<bool> {
        let Some(room) = self.joined(room_id) else { return Ok(false) };
        let id = room_id.as_str();
        let since = self.db.since(now_ms());
        let Some(progress) = self.db.progress(id)? else {
            // New to the index: its newest page, then fill back.
            let page = fetch(&room, None).await?;
            let parsed = self.parse_page(&room, &page.chunk).await;
            let progress = Progress {
                newest_event: page.chunk.first().and_then(|e| e.event_id()).map(|e| e.to_string()),
                back_token: page.end.clone(),
                oldest_ts: oldest_ts(&page.chunk),
                complete: page.end.is_none() || page.chunk.is_empty(),
            };
            self.db.write(id, &parsed, Some(&progress))?;
            return Ok(progress.needs_backfill(since));
        };
        let mut from = None;
        let mut newest = None;
        loop {
            let page = fetch(&room, from.take()).await?;
            if newest.is_none() {
                newest = page.chunk.first().and_then(|e| e.event_id()).map(|e| e.to_string());
            }
            let known = progress.newest_event.as_deref();
            let stop = page.chunk.iter().position(|e| known.is_some() && e.event_id().map(|i| i.as_str()) == known);
            let fresh = &page.chunk[..stop.unwrap_or(page.chunk.len())];
            let parsed = self.parse_page(&room, fresh).await;
            let at_start = page.end.is_none() || page.chunk.is_empty();
            // Away longer than the period: a whole page from before it means
            // what's indexed is older still, so this walk becomes the chat's
            // progress.
            let past_period = stop.is_none() && since.is_some_and(|s| newest_ts(fresh).is_some_and(|t| t < s));
            if stop.is_none() && (at_start || past_period) {
                let p = Progress {
                    newest_event: newest.clone(),
                    back_token: page.end.clone(),
                    oldest_ts: oldest_ts(fresh),
                    complete: at_start,
                };
                self.db.write(id, &parsed, Some(&p))?;
                return Ok(p.needs_backfill(since));
            }
            self.db.write(id, &parsed, None)?;
            if stop.is_some() {
                break;
            }
            from = page.end;
        }
        if let Some(newest) = newest {
            self.db.set_newest(id, &newest)?;
        }
        Ok(progress.needs_backfill(since))
    }

    /// Indexes one more page of a chat's history. Returns whether it still
    /// needs more.
    async fn backfill(&self, room_id: &RoomId) -> Result<bool> {
        let Some(room) = self.joined(room_id) else { return Ok(false) };
        let id = room_id.as_str();
        let since = self.db.since(now_ms());
        let Some(progress) = self.db.progress(id)? else { return self.catch_up(room_id).await };
        if !progress.needs_backfill(since) {
            return Ok(false);
        }
        let page = fetch(&room, progress.back_token.clone()).await?;
        let parsed = self.parse_page(&room, &page.chunk).await;
        let oldest = match (progress.oldest_ts, oldest_ts(&page.chunk)) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let p = Progress {
            newest_event: progress.newest_event,
            back_token: page.end.clone(),
            oldest_ts: oldest,
            complete: page.end.is_none() || page.chunk.is_empty(),
        };
        self.db.write(id, &parsed, Some(&p))?;
        self.publish(true, None, false);
        Ok(p.needs_backfill(since))
    }

    /// Catches a chat up now, for its media page. Gives up after a few
    /// seconds, leaving it to the indexer.
    pub(crate) async fn catch_up_now(&self, room_id: &RoomId) {
        let result = tokio::time::timeout(Duration::from_secs(4), async {
            let _work = self.work.lock().await;
            self.catch_up(room_id).await
        })
        .await;
        match result {
            Ok(Ok(more)) => {
                self.jobs.lock().unwrap().catch_up.shift_remove(room_id);
                if more {
                    let mut jobs = self.jobs.lock().unwrap();
                    if !jobs.backfill.iter().any(|r| r == room_id) {
                        jobs.backfill.push_back(room_id.to_owned());
                    }
                }
                self.wake.notify_one();
            }
            Ok(Err(e)) => tracing::info!(%room_id, "couldn't catch the chat up: {e:#}"),
            Err(_) => tracing::info!(%room_id, "catching the chat up took too long"),
        }
    }

    async fn parse_page(&self, room: &Room, events: &[TimelineEvent]) -> Vec<Parsed> {
        let mut names: HashMap<OwnedUserId, Option<String>> = HashMap::new();
        let mut out = Vec::with_capacity(events.len());
        for ev in events {
            let Ok(json) = serde_json::from_str::<Value>(ev.raw().json().get()) else { continue };
            let mut parsed = parse(room.room_id().as_str(), &json);
            if let Parsed::Message(row) = &mut parsed {
                row.sender_name = sender_name(room, &row.sender, &mut names).await;
            }
            out.push(parsed);
        }
        out
    }

    /// Searches the server for what the index doesn't hold, newest first.
    /// Asks for a few pages if the first ones only repeat the index.
    pub(crate) async fn search_server(
        &self,
        text: &str,
        room_id: Option<&str>,
        since: Option<i64>,
        until: Option<i64>,
        mut next: Option<String>,
    ) -> Result<(Vec<(Row, String)>, Option<String>)> {
        let mut out = Vec::new();
        let mut names: HashMap<OwnedUserId, Option<String>> = HashMap::new();
        for _ in 0..5 {
            let mut criteria = Criteria::new(text.to_owned());
            criteria.order_by = Some(OrderBy::Recent);
            criteria.filter.types = Some(vec!["m.room.message".to_owned()]);
            if let Some(room_id) = room_id {
                criteria.filter.rooms = Some(vec![RoomId::parse(room_id)?]);
            }
            let mut categories = Categories::new();
            categories.room_events = Some(criteria);
            let mut request = SearchRequest::new(categories);
            request.next_batch = next.take();
            let response = self.client.send(request).await?;
            let events = response.search_categories.room_events;
            let mut rows = Vec::new();
            let mut past_since = false;
            for result in events.results {
                let Some(raw) = result.result else { continue };
                let Ok(json) = serde_json::from_str::<Value>(raw.json().get()) else { continue };
                let Parsed::Message(row) = parse("", &json) else { continue };
                if since.is_some_and(|s| row.ts < s) {
                    past_since = true;
                    break;
                }
                if until.is_some_and(|u| row.ts >= u) || row.room_id.is_empty() {
                    continue;
                }
                rows.push(row);
            }
            let ids: Vec<String> = rows.iter().map(|r| r.event_id.clone()).collect();
            let indexed = self.db.contains(&ids)?;
            for mut row in rows.into_iter().filter(|r| !indexed.contains(&r.event_id)) {
                if let Some(room) = RoomId::parse(&row.room_id).ok().and_then(|id| self.client.get_room(&id)) {
                    row.sender_name = sender_name(&room, &row.sender, &mut names).await;
                }
                let snippet = highlight(&row.body, text, 160);
                out.push((row, snippet));
            }
            next = if past_since { None } else { events.next_batch };
            if out.len() >= 20 || next.is_none() {
                break;
            }
        }
        Ok((out, next))
    }

    /// A page of a chat's media, files or links: from the index, then, once
    /// it has nothing older, from the server's history (links excepted:
    /// finding them needs every message).
    pub(crate) async fn media_page(
        &self,
        room_id: &str,
        tab: MediaTab,
        cursor: Option<&str>,
        limit: u32,
    ) -> Result<(Vec<(Row, Option<String>)>, Option<String>)> {
        let id = RoomId::parse(room_id)?;
        let cursor = match cursor {
            None => {
                self.catch_up_now(&id).await;
                Cursor::Index { ts: i64::MAX, event_id: String::new(), url: String::new() }
            }
            Some(c) => Cursor::decode(c).ok_or_else(|| anyhow!("bad media cursor"))?,
        };
        match cursor {
            Cursor::Index { ts, event_id, url } => {
                let rows = self.db.media(room_id, &tab, Some((ts, &event_id, &url)), limit)?;
                if rows.len() as u32 == limit {
                    let (last, url) = rows.last().map(|(r, u)| (r, u.clone())).unwrap();
                    let next = Cursor::Index {
                        ts: last.ts,
                        event_id: last.event_id.clone(),
                        url: url.unwrap_or_default(),
                    };
                    return Ok((rows, Some(next.encode())));
                }
                let next = match (&tab, self.db.progress(room_id)?) {
                    (MediaTab::Links, _) => None,
                    (_, Some(p)) if p.complete => None,
                    (_, Some(p)) => p.back_token.map(|t| Cursor::Server(Some(t)).encode()),
                    (_, None) => Some(Cursor::Server(None).encode()),
                };
                Ok((rows, next))
            }
            Cursor::Server(token) => {
                let room = self.client.get_room(&id).ok_or_else(|| anyhow!("unknown room"))?;
                let mut options = MessagesOptions::backward();
                options.from = token;
                options.limit = UInt::from(100u32);
                options.filter.types = Some(vec!["m.room.message".to_owned()]);
                options.filter.url_filter = Some(UrlFilter::EventsWithUrl);
                let page = room.messages(options).await?;
                let wanted: &[i64] = match tab {
                    MediaTab::Media => &[KIND_IMAGE, KIND_VIDEO],
                    _ => &[KIND_AUDIO, KIND_FILE],
                };
                let rows = self
                    .parse_page(&room, &page.chunk)
                    .await
                    .into_iter()
                    .filter_map(|p| match p {
                        Parsed::Message(row) if wanted.contains(&row.kind) => Some((row, None)),
                        _ => None,
                    })
                    .collect();
                let next = (!page.chunk.is_empty()).then_some(page.end).flatten();
                Ok((rows, next.map(|t| Cursor::Server(Some(t)).encode())))
            }
        }
    }

    fn status(&self, indexing: bool, error: Option<String>) -> IndexStatus {
        let since = self.db.since(now_ms());
        let chats = self.client.joined_rooms().iter().filter(|r| !r.is_space()).count() as u32;
        let (messages, done) = self.db.counts(since).unwrap_or_default();
        IndexStatus {
            period_days: self.db.period_days(),
            since_ms: since,
            chats,
            chats_done: done.min(chats),
            messages,
            bytes: self.db.bytes() as i64,
            indexing,
            error,
        }
    }

    /// Tells the app how indexing is going, at most twice a second unless
    /// `force`d.
    fn publish(&self, indexing: bool, error: Option<String>, force: bool) {
        {
            let mut last = self.last_status.lock().unwrap();
            let changed = self.status.borrow().indexing != indexing;
            if !force && !changed && last.is_some_and(|t| t.elapsed() < Duration::from_millis(500)) {
                return;
            }
            *last = Some(Instant::now());
        }
        self.status.send_replace(self.status(indexing, error));
    }
}

async fn fetch(room: &Room, from: Option<String>) -> Result<Messages> {
    let mut options = MessagesOptions::backward();
    options.from = from;
    options.limit = UInt::from(PAGE);
    options.filter.types =
        Some(vec!["m.room.message".to_owned(), "m.room.redaction".to_owned(), "m.room.encrypted".to_owned()]);
    Ok(room.messages(options).await?)
}

fn oldest_ts(events: &[TimelineEvent]) -> Option<i64> {
    events.iter().filter_map(|e| e.timestamp()).map(|t| i64::from(t.get())).min()
}

fn newest_ts(events: &[TimelineEvent]) -> Option<i64> {
    events.iter().filter_map(|e| e.timestamp()).map(|t| i64::from(t.get())).max()
}

async fn sender_name(room: &Room, sender: &str, names: &mut HashMap<OwnedUserId, Option<String>>) -> Option<String> {
    let user = UserId::parse(sender).ok()?;
    if let Some(name) = names.get(&user) {
        return name.clone();
    }
    let name = room
        .get_member_no_sync(&user)
        .await
        .ok()
        .flatten()
        .and_then(|m| m.display_name().map(str::to_owned));
    names.insert(user, name.clone());
    name
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn text(id: &str, ts: i64, body: &str) -> Value {
        json!({
            "type": "m.room.message", "event_id": id, "sender": "@a:x", "origin_server_ts": ts,
            "content": { "msgtype": "m.text", "body": body }
        })
    }

    fn edit(id: &str, ts: i64, original: &str, body: &str) -> Value {
        json!({
            "type": "m.room.message", "event_id": id, "sender": "@a:x", "origin_server_ts": ts,
            "content": {
                "msgtype": "m.text", "body": format!("* {body}"),
                "m.new_content": { "msgtype": "m.text", "body": body },
                "m.relates_to": { "rel_type": "m.replace", "event_id": original }
            }
        })
    }

    fn page(evs: &[Value]) -> Vec<Parsed> {
        evs.iter().map(|e| parse("!r:x", e)).collect()
    }

    fn search(db: &Db, q: &str) -> Vec<String> {
        db.search(&Query { text: q, room_id: None, since: None, until: None, offset: 0, limit: 50 })
            .unwrap()
            .into_iter()
            .map(|(r, _)| r.event_id)
            .collect()
    }

    #[test]
    fn reads_media_captions_and_file_names() {
        let ev = json!({
            "type": "m.room.message", "event_id": "$1", "sender": "@a:x", "origin_server_ts": 5,
            "content": {
                "msgtype": "m.image", "body": "Sunset at the pier", "filename": "IMG_1.jpg", "url": "mxc://x/1",
                "info": { "mimetype": "image/jpeg", "w": 800, "h": 600, "size": 1234, "thumbnail_url": "mxc://x/t" }
            }
        });
        let Parsed::Message(row) = parse("!r:x", &ev) else { panic!() };
        assert_eq!(row.kind, KIND_IMAGE);
        assert_eq!(row.body, "Sunset at the pier");
        assert_eq!(row.name.as_deref(), Some("IMG_1.jpg"));
        assert_eq!((row.width, row.height, row.size), (Some(800), Some(600), Some(1234)));
        assert_eq!(row.thumbnail_mxc.as_deref(), Some("mxc://x/t"));

        // No caption: the file name is what's searched.
        let ev = json!({
            "type": "m.room.message", "event_id": "$2", "sender": "@a:x", "origin_server_ts": 5,
            "content": { "msgtype": "m.file", "body": "invoice.pdf", "url": "mxc://x/2" }
        });
        let Parsed::Message(row) = parse("!r:x", &ev) else { panic!() };
        assert_eq!((row.kind, row.body.as_str()), (KIND_FILE, "invoice.pdf"));

        // Voice notes and redacted messages are skipped.
        let voice = json!({
            "type": "m.room.message", "event_id": "$3", "sender": "@a:x", "origin_server_ts": 5,
            "content": { "msgtype": "m.audio", "body": "Voice message", "url": "mxc://x/3", "org.matrix.msc3245.voice": {} }
        });
        assert_eq!(parse("!r:x", &voice), Parsed::Skip);
        let redacted = json!({
            "type": "m.room.message", "event_id": "$4", "sender": "@a:x", "origin_server_ts": 5, "content": {}
        });
        assert_eq!(parse("!r:x", &redacted), Parsed::Skip);
    }

    #[test]
    fn strips_reply_fallbacks() {
        let ev = json!({
            "type": "m.room.message", "event_id": "$1", "sender": "@a:x", "origin_server_ts": 5,
            "content": {
                "msgtype": "m.text", "body": "> <@b:x> where?\n\nthe pub",
                "m.relates_to": { "m.in_reply_to": { "event_id": "$0" } }
            }
        });
        let Parsed::Message(row) = parse("!r:x", &ev) else { panic!() };
        assert_eq!(row.body, "the pub");
    }

    #[test]
    fn finds_links() {
        assert_eq!(
            links("see https://example.com/a?b=1, and (http://x.org/y). not ftp://z or https://"),
            vec!["https://example.com/a?b=1", "http://x.org/y"]
        );
    }

    #[test]
    fn searches_by_word_prefix_newest_first() {
        let db = Db::open_in_memory().unwrap();
        db.write(
            "!r:x",
            &page(&[text("$3", 30, "Café tonight?"), text("$2", 20, "dinner at the café"), text("$1", 10, "lunch")]),
            None,
        )
        .unwrap();
        assert_eq!(search(&db, "caf"), vec!["$3", "$2"]);
        // Accents don't matter, and every word must match.
        assert_eq!(search(&db, "cafe dinner"), vec!["$2"]);
        assert_eq!(search(&db, "\"*)"), Vec::<String>::new());
        let hits = db
            .search(&Query { text: "din", room_id: Some("!r:x"), since: Some(15), until: Some(25), offset: 0, limit: 5 })
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].1, format!("{MARK_START}dinner{MARK_END} at the café"));
    }

    #[test]
    fn applies_edits_in_either_order_and_unsends() {
        let db = Db::open_in_memory().unwrap();
        // Paging back, the edit arrives before the message it edits.
        db.write("!r:x", &page(&[edit("$2", 20, "$1", "see https://b.example"), text("$1", 10, "see https://a.example")]), None)
            .unwrap();
        assert_eq!(search(&db, "b.example"), vec!["$1"]);
        assert!(search(&db, "a.example").is_empty());
        let links = db.media("!r:x", &MediaTab::Links, None, 10).unwrap();
        assert_eq!(links.into_iter().map(|(_, u)| u.unwrap()).collect::<Vec<_>>(), vec!["https://b.example"]);

        // Live, an edit replaces the indexed text; an older one doesn't.
        db.write("!r:x", &page(&[edit("$3", 30, "$1", "final words")]), None).unwrap();
        db.write("!r:x", &page(&[edit("$0", 15, "$1", "stale")]), None).unwrap();
        assert_eq!(search(&db, "final"), vec!["$1"]);
        assert!(search(&db, "stale").is_empty());
        assert!(db.media("!r:x", &MediaTab::Links, None, 10).unwrap().is_empty());

        // Someone else can't edit it.
        let mut other = edit("$4", 40, "$1", "hijack");
        other["sender"] = json!("@b:x");
        db.write("!r:x", &page(&[other]), None).unwrap();
        assert!(search(&db, "hijack").is_empty());

        let unsend = json!({
            "type": "m.room.redaction", "event_id": "$5", "sender": "@a:x", "origin_server_ts": 50,
            "content": { "redacts": "$1" }
        });
        db.write("!r:x", &page(&[unsend]), None).unwrap();
        assert!(search(&db, "final").is_empty());
    }

    #[test]
    fn pages_media_and_prunes_to_the_period() {
        let db = Db::open_in_memory().unwrap();
        let day = 86_400_000;
        let now = 400 * day;
        let image = |id: &str, ts: i64| {
            json!({
                "type": "m.room.message", "event_id": id, "sender": "@a:x", "origin_server_ts": ts,
                "content": { "msgtype": "m.image", "body": "photo.jpg", "url": format!("mxc://x/{id}") }
            })
        };
        db.write(
            "!r:x",
            &page(&[image("$c", now - day), image("$b", now - day), image("$a", now - 380 * day), text("$t", now, "hi")]),
            None,
        )
        .unwrap();
        let first = db.media("!r:x", &MediaTab::Media, None, 2).unwrap();
        assert_eq!(first.iter().map(|(r, _)| r.event_id.as_str()).collect::<Vec<_>>(), vec!["$c", "$b"]);
        let last = &first[1].0;
        let rest = db.media("!r:x", &MediaTab::Media, Some((last.ts, &last.event_id, "")), 2).unwrap();
        assert_eq!(rest.iter().map(|(r, _)| r.event_id.as_str()).collect::<Vec<_>>(), vec!["$a"]);

        // A year by default: the 380-day-old photo goes.
        assert_eq!(db.prune(now).unwrap(), 1);
        assert_eq!(db.counts(db.since(now)).unwrap().0, 3);

        // Longer starts every chat again; shorter prunes.
        db.write("!r:x", &[], Some(&Progress { newest_event: Some("$t".into()), ..Progress::default() })).unwrap();
        assert!(db.set_period_days(0, now).unwrap());
        assert!(db.progress("!r:x").unwrap().is_none());
        assert!(db.set_period_days(30, now).unwrap());
        assert_eq!(db.counts(db.since(now)).unwrap().0, 3);
        assert!(db.set_period_days(0, now).unwrap());
        assert!(!db.set_period_days(0, now).unwrap());
    }

    #[test]
    fn needs_backfill_until_the_period_or_the_start() {
        let p = |oldest: Option<i64>, complete| Progress { oldest_ts: oldest, complete, ..Progress::default() };
        assert!(p(Some(100), false).needs_backfill(Some(50)));
        assert!(!p(Some(40), false).needs_backfill(Some(50)));
        assert!(!p(Some(100), true).needs_backfill(None));
        assert!(p(Some(100), false).needs_backfill(None));
    }

    #[test]
    fn cursors_round_trip() {
        for c in [
            Cursor::Index { ts: 5, event_id: "$e".into(), url: "https://a|b".into() },
            Cursor::Server(Some("t1_2".into())),
            Cursor::Server(None),
        ] {
            assert_eq!(Cursor::decode(&c.encode()), Some(c));
        }
    }

    #[test]
    fn highlights_server_results() {
        assert_eq!(highlight("Dinner at Dino's", "din", 100), format!("{MARK_START}Din{MARK_END}ner at {MARK_START}Din{MARK_END}o's"));
        let long = format!("{} needle {}", "a ".repeat(100), "b ".repeat(100));
        let h = highlight(&long, "needle", 40);
        assert!(h.starts_with('…') && h.ends_with('…') && h.contains(&format!("{MARK_START}needle{MARK_END}")));
    }
}
