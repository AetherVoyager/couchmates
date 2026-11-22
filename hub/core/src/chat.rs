//! The app's chat: a public channel for everyone, and private chats between
//! two people. Messages are kept in D1 for good. Apps send and page through
//! them with ordinary calls; the `ChatLive` Durable Object (in the Worker)
//! keeps a WebSocket open to every app and pushes each new message to the
//! people it's for. A socket that drops loses nothing: the app asks for what
//! came `after` its newest message when it reconnects.

use couchmates_core::api::{
    ChatChannel, ChatEvent, ChatMessage, ChatMessages, ChatOverview, ChatRead, ChatSend, OkResponse, Person,
};
use couchmates_core::rules::{PUBLIC_CHANNEL, chat_text, direct_channel};
use worker::{Env, Headers, Method, Request, RequestInit, Response, Result};

use crate::api::{authenticate, photo_path};
use crate::store::{ChatChannelRow, ChatRow, Store};
use crate::web::{self, json_error};

/// The binding of the `ChatLive` Durable Object.
pub const BINDING: &str = "CHAT";
/// The one `ChatLive` instance: a few friends fit on one easily.
pub const INSTANCE: &str = "chat";
/// The header the Worker passes the signed-in user to `ChatLive` in. The
/// object can only be reached through the Worker, which sets it.
pub const USER_HEADER: &str = "X-Couchmates-User";
/// Messages per page.
pub const PAGE: u32 = 50;

/// The two people of a private chat id, or None.
pub fn members(channel: &str) -> Option<(&str, &str)> {
    let (a, b) = channel.strip_prefix("dm:")?.split_once(':')?;
    (!a.is_empty() && !b.is_empty() && !b.contains(':') && a < b).then_some((a, b))
}

/// Whether [me] may read [channel].
pub fn readable(me: &str, channel: &str) -> bool {
    channel == PUBLIC_CHANNEL || members(channel).is_some_and(|(a, b)| a == me || b == me)
}

/// Where a message [me] sends to [channel] goes: the channel id and, for a
/// private chat, the other person. [channel] is `public`, `dm:<user id>`, or
/// a full private chat id with [me] in it.
pub fn send_target(me: &str, channel: &str) -> Option<(String, Option<String>)> {
    if channel == PUBLIC_CHANNEL {
        return Some((PUBLIC_CHANNEL.into(), None));
    }
    let other = match members(channel) {
        Some((a, b)) if a == me => b,
        Some((a, b)) if b == me => a,
        Some(_) => return None,
        None => channel.strip_prefix("dm:").filter(|id| !id.is_empty() && !id.contains(':'))?,
    };
    (other != me).then(|| (direct_channel(me, other), Some(other.to_string())))
}

pub fn message(row: &ChatRow) -> ChatMessage {
    ChatMessage {
        id: row.id,
        channel: row.channel.clone(),
        from: Person {
            id: row.sender.clone(),
            name: row.from_name.clone(),
            photo: photo_path(&row.sender, row.from_photo),
        },
        text: row.text.clone(),
        sent_at: row.sent_at,
    }
}

/// The public channel (listed even before anyone wrote), then private chats.
pub fn overview(public: Option<ChatChannelRow>, direct: Vec<ChatChannelRow>) -> ChatOverview {
    let mut channels = vec![ChatChannel {
        id: PUBLIC_CHANNEL.into(),
        person: None,
        unread: public.as_ref().map_or(0, |p| p.unread.max(0) as u32),
        last: public.map(|p| message(&p.last())),
    }];
    channels.extend(direct.into_iter().filter_map(|row| {
        let id = row.other_id.clone()?;
        let person = Person { photo: photo_path(&id, row.other_photo), name: row.other_name.clone()?, id };
        Some(ChatChannel {
            id: row.channel.clone(),
            person: Some(person),
            unread: row.unread.max(0) as u32,
            last: Some(message(&row.last())),
        })
    }));
    ChatOverview { channels }
}

/// A page from [rows] (oldest first, one more than [limit] when there are
/// more). With [newer] the extra one is the newest; otherwise the oldest.
pub fn page(mut rows: Vec<ChatRow>, limit: u32, newer: bool) -> ChatMessages {
    let more = rows.len() > limit as usize;
    if more {
        if newer {
            rows.truncate(limit as usize);
        } else {
            rows.drain(..rows.len() - limit as usize);
        }
    }
    ChatMessages { messages: rows.iter().map(message).collect(), more }
}

fn query_i64(req: &Request, key: &str) -> Option<i64> {
    let url = req.url().ok()?;
    let value = url.query_pairs().find(|(k, _)| k == key)?.1.parse().ok()?;
    Some(value)
}

fn query(req: &Request, key: &str) -> Option<String> {
    let url = req.url().ok()?;
    url.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.into_owned())
}

/// `GET /api/app/chat`.
pub async fn channels(req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let (public, direct) = store.chat_channels(&user.id).await?;
    web::json(&overview(public, direct), 200)
}

/// `GET /api/app/chat/messages?channel=…&before=…&after=…`.
pub async fn messages(req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let channel = query(&req, "channel").unwrap_or_default();
    if !readable(&user.id, &channel) {
        return json_error("That chat isn't yours to read.", 404);
    }
    let after = query_i64(&req, "after");
    let rows = store.chat_page(&channel, query_i64(&req, "before"), after, PAGE).await?;
    web::json(&page(rows, PAGE, after.is_some()), 200)
}

/// `POST /api/app/chat/send`: saves the message, then pushes it live.
pub async fn send(mut req: Request, store: &Store, env: &Env) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<ChatSend>().await else {
        return json_error("Send {\"channel\": \"public\", \"text\": \"…\"}.", 400);
    };
    let Some(text) = chat_text(&body.text) else {
        return json_error("Write something first (at most 2000 characters).", 400);
    };
    let Some((channel, recipient)) = send_target(&user.id, &body.channel) else {
        return json_error("There's no such chat.", 404);
    };
    if let Some(other) = &recipient {
        let found = store.user(other).await?;
        if found.is_none_or(|u| u.disabled != 0) {
            return json_error("That person isn't on the Hub any more.", 404);
        }
    }
    let row = store.add_chat(&channel, &user.id, recipient.as_deref(), &text).await?;
    // Everyone reads their own message as read.
    store.mark_chat_read(&user.id, &channel, row.id).await?;
    let message = message(&row);
    let to = recipient.map(|other| vec![user.id.clone(), other]);
    if let Err(e) = push(env, to, &ChatEvent { kind: "message".into(), message: Some(message.clone()) }).await {
        worker::console_warn!("chat push failed: {e}");
    }
    web::json(&message, 200)
}

/// `POST /api/app/chat/read`.
pub async fn read(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<ChatRead>().await else {
        return json_error("Send {\"channel\": \"public\", \"up_to\": 120}.", 400);
    };
    if !readable(&user.id, &body.channel) {
        return json_error("That chat isn't yours to read.", 404);
    }
    store.mark_chat_read(&user.id, &body.channel, body.up_to).await?;
    web::json(&OkResponse { ok: true }, 200)
}

/// `GET /api/app/chat/live`: a WebSocket that gets this user's new messages.
pub async fn live(req: Request, store: &Store, env: &Env) -> Result<Response> {
    let upgrade = req.headers().get("Upgrade")?.unwrap_or_default();
    // Signed in comes first, so a stray request learns nothing.
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    if !upgrade.eq_ignore_ascii_case("websocket") {
        return json_error("Open this as a WebSocket.", 426);
    }
    let headers = Headers::new();
    headers.set("Upgrade", "websocket")?;
    headers.set(USER_HEADER, &user.id)?;
    let mut init = RequestInit::new();
    init.with_method(Method::Get).with_headers(headers);
    let inner = Request::new_with_init("https://chat/live", &init)?;
    env.durable_object(BINDING)?.get_by_name(INSTANCE)?.fetch_with_request(inner).await
}

/// What the Worker asks `ChatLive` to send: [frame] to the sockets of the
/// users in [to], or to everyone when it's None.
#[derive(serde::Serialize, serde::Deserialize)]
pub struct Push {
    pub to: Option<Vec<String>>,
    pub frame: String,
}

async fn push(env: &Env, to: Option<Vec<String>>, event: &ChatEvent) -> Result<()> {
    let body = serde_json::to_string(&Push { to, frame: serde_json::to_string(event)? })?;
    let headers = Headers::new();
    headers.set("Content-Type", "application/json")?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post).with_headers(headers).with_body(Some(body.into()));
    let inner = Request::new_with_init("https://chat/push", &init)?;
    env.durable_object(BINDING)?.get_by_name(INSTANCE)?.fetch_with_request(inner).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: i64) -> ChatRow {
        ChatRow {
            id,
            channel: "public".into(),
            sender: "aaaa".into(),
            from_name: "Alice".into(),
            from_photo: Some(7),
            text: format!("m{id}"),
            sent_at: 100 + id,
        }
    }

    #[test]
    fn only_members_read_a_private_chat() {
        assert!(readable("aaaa", "public"));
        assert!(readable("aaaa", "dm:aaaa:bbbb"));
        assert!(readable("bbbb", "dm:aaaa:bbbb"));
        assert!(!readable("cccc", "dm:aaaa:bbbb"));
        // Not sorted, or not a private chat id at all.
        assert!(!readable("aaaa", "dm:bbbb:aaaa"));
        assert!(!readable("aaaa", "dm:aaaa"));
        assert!(!readable("aaaa", "dm:aaaa:bbbb:cccc"));
        assert!(!readable("aaaa", "other"));
    }

    #[test]
    fn sending_finds_the_chat() {
        assert_eq!(send_target("bbbb", "public"), Some(("public".into(), None)));
        assert_eq!(send_target("bbbb", "dm:aaaa"), Some(("dm:aaaa:bbbb".into(), Some("aaaa".into()))));
        assert_eq!(send_target("bbbb", "dm:aaaa:bbbb"), Some(("dm:aaaa:bbbb".into(), Some("aaaa".into()))));
        assert_eq!(send_target("cccc", "dm:aaaa:bbbb"), None);
        assert_eq!(send_target("aaaa", "dm:aaaa"), None, "not to yourself");
        assert_eq!(send_target("aaaa", "dm:"), None);
        assert_eq!(send_target("aaaa", "elsewhere"), None);
    }

    #[test]
    fn pages_drop_the_extra_row() {
        let older = page((1..=4).map(row).collect(), 3, false);
        assert!(older.more);
        assert_eq!(older.messages.iter().map(|m| m.id).collect::<Vec<_>>(), [2, 3, 4]);
        let newer = page((1..=4).map(row).collect(), 3, true);
        assert_eq!(newer.messages.iter().map(|m| m.id).collect::<Vec<_>>(), [1, 2, 3]);
        let all = page((1..=2).map(row).collect(), 3, false);
        assert!(!all.more && all.messages.len() == 2);
        assert_eq!(all.messages[0].from.photo.as_deref(), Some("/api/app/photos/aaaa?v=7"));
    }

    #[test]
    fn the_public_channel_is_always_listed() {
        let view = overview(None, vec![]);
        assert_eq!(view.channels.len(), 1);
        assert_eq!(view.channels[0].id, "public");
        assert_eq!(view.channels[0].unread, 0);
        assert!(view.channels[0].last.is_none());
    }
}
