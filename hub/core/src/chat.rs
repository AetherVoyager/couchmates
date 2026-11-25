//! The app's chat: a public channel for everyone, and private chats between
//! two people. Messages are kept in D1 for good. Apps send and page through
//! them with ordinary calls; the `ChatLive` Durable Object (in the Worker)
//! keeps a WebSocket open to every app and pushes each new message to the
//! people it's for. A socket that drops loses nothing: the app asks for what
//! came `after` its newest message when it reconnects.
//!
//! Moderation: chat admins (a flag on the user, set on the dashboard) show
//! with a verified badge, may delete anyone's public messages and mute
//! people. Everyone else is held to [RATE_MAX] messages per [RATE_SECS]
//! seconds, and words on the dashboard's blocked list are starred out.

use couchmates_core::api::{
    ChatChannel, ChatDelete, ChatEvent, ChatMessage, ChatMessages, ChatMute, ChatOverview, ChatRead, ChatSend,
    OkResponse, Person,
};
pub use couchmates_core::rules::CHAT_MUTED_FOREVER;
use couchmates_core::rules::{PUBLIC_CHANNEL, chat_text, direct_channel};
use worker::{Env, Headers, Method, Request, RequestInit, Response, Result};

use crate::api::{authenticate, photo_path};
use crate::store::{ChatChannelRow, ChatRow, Store, now};
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
/// The setting with the blocked words, one per line or comma-separated.
pub const BLOCKED_WORDS: &str = "chat_blocked_words";
/// Everyone but chat admins may send at most [RATE_MAX] messages in any
/// [RATE_SECS] seconds.
pub const RATE_MAX: i64 = 5;
pub const RATE_SECS: i64 = 10;

/// The blocked words in [setting]: lowercased, one per line or comma.
pub fn parse_words(setting: &str) -> Vec<String> {
    let mut words: Vec<String> =
        setting.split([',', '\n']).map(|w| w.trim().to_lowercase()).filter(|w| !w.is_empty()).collect();
    words.sort();
    words.dedup();
    words
}

/// [text] with each whole word from [words] (any case) starred out, so
/// "class" stays when "ass" is blocked. A blocked entry with a space in it
/// matches that run of words.
pub fn mask_words(text: &str, words: &[String]) -> String {
    if words.is_empty() {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let lower: Vec<char> = text.chars().flat_map(char::to_lowercase).collect();
    // Lowercasing can change the length (rarely); then match on the text as typed.
    let hay = if lower.len() == chars.len() { &lower } else { &chars };
    let mut out = chars.clone();
    let boundary = |i: usize| i >= chars.len() || !chars[i].is_alphanumeric();
    for word in words {
        let w: Vec<char> = word.chars().collect();
        if w.is_empty() || w.len() > hay.len() {
            continue;
        }
        for start in 0..=hay.len() - w.len() {
            let end = start + w.len();
            if hay[start..end] == w[..] && (start == 0 || boundary(start - 1)) && boundary(end) {
                for c in &mut out[start..end] {
                    if !c.is_whitespace() {
                        *c = '*';
                    }
                }
            }
        }
    }
    out.into_iter().collect()
}

/// When a mute set at [now] for [minutes] ends: None lifts it, and no
/// minutes at all lasts until lifted.
pub fn mute_until(now: i64, minutes: Option<u32>) -> Option<i64> {
    match minutes {
        Some(0) => None,
        Some(m) => Some(now + i64::from(m) * 60),
        None => Some(CHAT_MUTED_FOREVER),
    }
}

/// What a muted user is told when they try to send.
pub fn muted_message(until: i64, now: i64) -> String {
    if until >= CHAT_MUTED_FOREVER {
        return "A chat admin has turned off sending messages for you.".into();
    }
    let minutes = ((until - now) + 59) / 60;
    match minutes {
        ..=1 => "A chat admin muted you. You can write again in a minute.".into(),
        2..=119 => format!("A chat admin muted you. You can write again in {minutes} minutes."),
        _ => {
            let hours = (minutes + 59) / 60;
            if hours < 48 {
                format!("A chat admin muted you. You can write again in {hours} hours.")
            } else {
                format!("A chat admin muted you. You can write again in {} days.", (hours + 23) / 24)
            }
        }
    }
}

/// Whether [me] may delete [row]: their own message, or any public one for
/// a chat admin.
pub fn may_delete(me: &str, admin: bool, row: &ChatRow) -> bool {
    row.sender == me || (admin && row.channel == PUBLIC_CHANNEL)
}

/// Who a change to [row] is pushed to: everyone for the public channel,
/// else the two people of the private chat.
fn audience(row: &ChatRow) -> Option<Vec<String>> {
    (row.channel != PUBLIC_CHANNEL)
        .then(|| [Some(row.sender.clone()), row.recipient.clone()].into_iter().flatten().collect())
}

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
            admin: row.from_admin != 0,
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
        let person = Person {
            photo: photo_path(&id, row.other_photo),
            name: row.other_name.clone()?,
            admin: row.other_admin != 0,
            id,
        };
        Some(ChatChannel {
            id: row.channel.clone(),
            person: Some(person),
            unread: row.unread.max(0) as u32,
            last: Some(message(&row.last())),
        })
    }));
    ChatOverview { channels, admin: false, muted_until: None }
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
    let mut view = overview(public, direct);
    view.admin = user.is_chat_admin();
    view.muted_until = user.muted_until(now());
    web::json(&view, 200)
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
    let at = now();
    if !user.is_chat_admin() {
        if let Some(until) = user.muted_until(at) {
            return json_error(&muted_message(until, at), 403);
        }
        if store.chat_sent_since(&user.id, at - RATE_SECS + 1).await? >= RATE_MAX {
            return json_error("You're sending messages too fast. Wait a few seconds.", 429);
        }
    }
    let words = parse_words(&store.setting(BLOCKED_WORDS).await?.unwrap_or_default());
    let text = mask_words(&text, &words);
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

/// `POST /api/app/chat/delete`: deletes a message and tells the apps that
/// show it.
pub async fn delete(mut req: Request, store: &Store, env: &Env) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<ChatDelete>().await else {
        return json_error("Send {\"id\": 120}.", 400);
    };
    let Some(row) = store.chat_message(body.id).await?.filter(|r| readable(&user.id, &r.channel)) else {
        return json_error("That message is gone already.", 404);
    };
    if !may_delete(&user.id, user.is_chat_admin(), &row) {
        return json_error("Only chat admins can delete other people's messages.", 403);
    }
    store.delete_chat(row.id).await?;
    let event = ChatEvent { kind: "deleted".into(), message: Some(message(&row)) };
    if let Err(e) = push(env, audience(&row), &event).await {
        worker::console_warn!("chat push failed: {e}");
    }
    web::json(&OkResponse { ok: true }, 200)
}

/// `POST /api/app/chat/mute`: a chat admin mutes someone, or lifts it.
pub async fn mute(mut req: Request, store: &Store, env: &Env) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    if !user.is_chat_admin() {
        return json_error("Only chat admins can mute people.", 403);
    }
    let Ok(body) = req.json::<ChatMute>().await else {
        return json_error("Send {\"user\": \"<user id>\", \"minutes\": 60}.", 400);
    };
    let Some(target) = store.user(&body.user).await? else {
        return json_error("That person isn't on the Hub.", 404);
    };
    if target.id == user.id {
        return json_error("You can't mute yourself.", 400);
    }
    if target.is_chat_admin() {
        return json_error("Chat admins can't be muted.", 403);
    }
    store.set_chat_muted(&target.id, mute_until(now(), body.minutes)).await?;
    refresh(env, &target.id).await;
    web::json(&OkResponse { ok: true }, 200)
}

/// Tells [user_id]'s apps that their chat standing changed. Never fails.
pub async fn refresh(env: &Env, user_id: &str) {
    if let Err(e) =
        push(env, Some(vec![user_id.to_string()]), &ChatEvent { kind: "refresh".into(), message: None }).await
    {
        worker::console_warn!("chat push failed: {e}");
    }
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
            recipient: None,
            from_name: "Alice".into(),
            from_photo: Some(7),
            from_admin: 0,
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
    fn blocked_words_are_starred_as_whole_words() {
        let words = parse_words(" Ass,\nheck , ,HECK\nbad word");
        assert_eq!(words, ["ass", "bad word", "heck"]);
        assert_eq!(mask_words("What the HECK, ass!", &words), "What the ****, ***!");
        assert_eq!(mask_words("a classic hecktic pass", &words), "a classic hecktic pass");
        assert_eq!(mask_words("so bad  word, bad words", &words), "so bad  word, bad words");
        assert_eq!(mask_words("a bad word here", &words), "a *** **** here");
        assert_eq!(mask_words("heck🍿heck", &words), "****🍿****");
        assert_eq!(mask_words("hi", &[]), "hi");
    }

    #[test]
    fn mutes_end_or_last() {
        assert_eq!(mute_until(1000, Some(0)), None);
        assert_eq!(mute_until(1000, Some(60)), Some(1000 + 3600));
        assert_eq!(mute_until(1000, None), Some(CHAT_MUTED_FOREVER));
        assert!(muted_message(CHAT_MUTED_FOREVER, 0).contains("turned off"));
        assert!(muted_message(1030, 1000).ends_with("in a minute."));
        assert!(muted_message(1000 + 3600, 1000).ends_with("in 60 minutes."));
        assert!(muted_message(1000 + 86_400, 1000).ends_with("in 24 hours."));
        assert!(muted_message(1000 + 7 * 86_400, 1000).ends_with("in 7 days."));
    }

    #[test]
    fn who_may_delete() {
        let public = row(1);
        assert!(may_delete("aaaa", false, &public), "your own");
        assert!(!may_delete("bbbb", false, &public));
        assert!(may_delete("bbbb", true, &public), "an admin, in public");
        let dm = ChatRow { channel: "dm:aaaa:bbbb".into(), recipient: Some("bbbb".into()), ..row(2) };
        assert!(!may_delete("bbbb", true, &dm), "not someone else's private message");
        assert!(may_delete("aaaa", false, &dm));
        assert_eq!(audience(&public), None);
        assert_eq!(audience(&dm), Some(vec!["aaaa".to_string(), "bbbb".to_string()]));
    }

    #[test]
    fn admins_show_as_such() {
        let m = message(&ChatRow { from_admin: 1, ..row(3) });
        assert!(m.from.admin);
        assert!(!message(&row(4)).from.admin);
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
