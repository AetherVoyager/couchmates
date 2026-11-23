//! The bot API (`/api/bot/*`): lets the admin's own program answer title requests. It sends
//! `Authorization: Bearer <bot token>` with the token made on the dashboard's Requests page. The Hub keeps only
//! the token's SHA-256, so a lost token is replaced, not shown again.
//!
//! | Call | Request | Response |
//! |---|---|---|
//! | `GET /api/bot/requests?status=open` | | [`MediaRequests`] |
//! | `POST /api/bot/requests/update` | [`MediaRequestUpdate`] | [`MediaRequest`] |
//! | `POST /api/bot/status` | [`BotStatus`] | `{"ok": true}` |
//!
//! `status` is the bot's heartbeat: what it's doing and what recently happened. The Overview page shows it, and
//! calls the bot offline when it hasn't reported for [`ONLINE_SECS`].
//!
//! `status` filters by `pending`, `approved`, `added`, `declined`, `open` (pending or approved, the default) or
//! `all`. When a webhook address is saved, a new request (or a declined one asked for again) is also POSTed there
//! as a [`BotWebhook`], signed in `x-couchmates-signature: sha256=<hex HMAC-SHA256 of the body>` keyed with the
//! hex SHA-256 of the bot token.
//!
//! The Hub only records answers. Getting the title is up to the admin's program.

use std::time::Duration;

use couchmates_core::api::{
    BotEvent, BotStatus, BotWebhook, MediaRequest, MediaRequestUpdate, MediaRequests, OkResponse, request_status,
};
use futures_util::future::{Either, join_all, select};
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use worker::{Delay, Fetch, Headers, Method, Request, RequestInit, Response, Result};

use crate::crypto::{password_matches, sha256_hex};
use crate::requests::{MAX_NOTE, to_api};
use crate::store::{Store, now};
use crate::web::{self, json_error};

/// The SHA-256 (hex) of the bot token. Not a secret by itself.
pub const TOKEN_HASH: &str = "bot_token_hash";
/// Where new requests are POSTed. Sealed, since such links often carry a key.
pub const WEBHOOK: &str = "bot_webhook_url";
/// The bot's last report ([`StoredBot`] as JSON), and its recent events ([`BotEvent`]s, oldest first).
pub const STATUS: &str = "bot_status";
pub const EVENTS: &str = "bot_events";
const WEBHOOK_TIMEOUT: Duration = Duration::from_secs(4);

/// A bot that reported this recently counts as online. It's meant to report every 30 seconds.
pub const ONLINE_SECS: i64 = 150;
const KEEP_EVENTS: usize = 50;
const EVENTS_PER_REPORT: usize = 20;
const MAX_TEXT: usize = 200;

/// The statuses a `status=` filter stands for.
pub fn statuses(filter: &str) -> Option<&'static [&'static str]> {
    use request_status::*;
    Some(match filter {
        "pending" => &[PENDING],
        "approved" => &[APPROVED],
        "added" => &[ADDED],
        "declined" => &[DECLINED],
        "all" => &[],
        "open" | "" => &[PENDING, APPROVED],
        _ => return None,
    })
}

/// Why [req] isn't from the bot, as the response to send; None when it is.
async fn refuse(req: &Request, store: &Store) -> Result<Option<Response>> {
    let Some(expected) = store.setting(TOKEN_HASH).await? else {
        return Ok(Some(json_error("No bot token is set up. Make one on the Hub's Requests page.", 401)?));
    };
    match web::bearer(req) {
        Some(token) if password_matches(&sha256_hex(&token), &expected) => Ok(None),
        _ => Ok(Some(json_error("Wrong bot token.", 401)?)),
    }
}

/// `GET /api/bot/requests?status=…`
pub async fn list(req: Request, store: &Store) -> Result<Response> {
    if let Some(r) = refuse(&req, store).await? {
        return Ok(r);
    }
    let url = req.url()?;
    let filter = url.query_pairs().find(|(k, _)| k == "status").map(|(_, v)| v.into_owned()).unwrap_or_default();
    let Some(wanted) = statuses(&filter) else {
        return json_error("status is pending, approved, added, declined, open or all.", 400);
    };
    let requests = store.media_requests("", wanted).await?.into_iter().map(to_api).collect();
    web::json(&MediaRequests { requests }, 200)
}

/// `POST /api/bot/requests/update`: sets a request's status, and its note when one is sent.
pub async fn update(mut req: Request, store: &Store) -> Result<Response> {
    if let Some(r) = refuse(&req, store).await? {
        return Ok(r);
    }
    let Ok(body) = req.json::<MediaRequestUpdate>().await else {
        return json_error("Send {\"id\": \"…\", \"status\": \"added\", \"note\": \"…\"}.", 400);
    };
    if !request_status::ALL.contains(&body.status.as_str()) {
        return json_error("status is pending, approved, added or declined.", 400);
    }
    let Some(current) = store.media_request(&body.id, "").await? else {
        return json_error("No request has that id.", 404);
    };
    let note = match body.note {
        Some(n) => Some(n.trim().chars().take(MAX_NOTE).collect::<String>()).filter(|n| !n.is_empty()),
        None => current.note,
    };
    store.set_request_status(&body.id, &body.status, note.as_deref()).await?;
    match store.media_request(&body.id, "").await? {
        Some(row) => web::json(&to_api(row), 200),
        None => json_error("No request has that id.", 404),
    }
}

/// The bot's last report, as the Hub keeps it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredBot {
    pub state: String,
    pub activity: String,
    pub version: String,
    /// When the Hub last heard from it (unix seconds, the Hub's clock).
    pub seen_at: i64,
}

/// What the Overview shows: the last report, if any, and recent events, newest first.
#[derive(Debug, Clone, Default)]
pub struct BotView {
    pub status: Option<StoredBot>,
    pub events: Vec<BotEvent>,
}

fn clip(text: &str, max: usize) -> String {
    text.trim().chars().take(max).collect()
}

/// [stored] plus the events of one report: levels and text tidied, times kept sane (the bot's clock may be off,
/// so a missing or future time becomes [now]), oldest first, the latest [`KEEP_EVENTS`] kept.
pub fn merge_events(mut stored: Vec<BotEvent>, incoming: Vec<BotEvent>, now: i64) -> Vec<BotEvent> {
    for e in incoming.into_iter().take(EVENTS_PER_REPORT) {
        let message = clip(&e.message, MAX_TEXT);
        if message.is_empty() {
            continue;
        }
        let level = if e.level == "error" { "error" } else { "info" }.to_string();
        let at = if e.at <= 0 || e.at > now { now } else { e.at };
        stored.push(BotEvent { at, level, message });
    }
    stored.sort_by_key(|e| e.at);
    let extra = stored.len().saturating_sub(KEEP_EVENTS);
    stored.drain(..extra);
    stored
}

/// `POST /api/bot/status`: the bot's heartbeat.
pub async fn status(mut req: Request, store: &Store) -> Result<Response> {
    if let Some(r) = refuse(&req, store).await? {
        return Ok(r);
    }
    let Ok(body) = req.json::<BotStatus>().await else {
        return json_error("Send {\"state\": \"idle\", \"activity\": \"…\", \"events\": []}.", 400);
    };
    if !["idle", "working", "error"].contains(&body.state.as_str()) {
        return json_error("state is idle, working or error.", 400);
    }
    let now = now();
    let stored = StoredBot {
        state: body.state,
        activity: clip(body.activity.as_deref().unwrap_or_default(), MAX_TEXT),
        version: clip(body.version.as_deref().unwrap_or_default(), 40),
        seen_at: now,
    };
    store.set_setting(STATUS, Some(&serde_json::to_string(&stored)?)).await?;
    if !body.events.is_empty() {
        let current = store.setting(EVENTS).await?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let merged = merge_events(current, body.events, now);
        store.set_setting(EVENTS, Some(&serde_json::to_string(&merged)?)).await?;
    }
    web::json(&OkResponse { ok: true }, 200)
}

/// What the Overview shows about the bot.
pub async fn view(store: &Store) -> Result<BotView> {
    let status = store.setting(STATUS).await?.and_then(|s| serde_json::from_str(&s).ok());
    let mut events: Vec<BotEvent> =
        store.setting(EVENTS).await?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    events.reverse();
    Ok(BotView { status, events })
}

/// The signature header's value for [body].
pub fn signature(token_hash: &str, body: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(token_hash.as_bytes()).expect("HMAC accepts any key length");
    mac.update(body.as_bytes());
    format!("sha256={}", hex::encode(mac.finalize().into_bytes()))
}

/// Tells the bot's webhook about each of [requests], when one is saved: one POST per request, sent together.
/// Best effort: a slow or broken webhook never stops a friend's request, and the bot can always catch up with
/// [list].
pub async fn notify(store: &Store, requests: &[MediaRequest]) {
    if requests.is_empty() {
        return;
    }
    let (Ok(Some(url)), Ok(Some(token_hash))) = (store.setting(WEBHOOK).await, store.setting(TOKEN_HASH).await) else {
        return;
    };
    let sends = requests.iter().map(|request| {
        let url = url.clone();
        let token_hash = token_hash.clone();
        async move {
            let event = BotWebhook { event: "request.created".into(), request: request.clone() };
            let body = serde_json::to_string(&event).ok()?;
            let headers = Headers::new();
            headers.set("content-type", "application/json").ok()?;
            headers.set("x-couchmates-event", &event.event).ok()?;
            headers.set("x-couchmates-signature", &signature(&token_hash, &body)).ok()?;
            let mut init = RequestInit::new();
            init.with_method(Method::Post).with_headers(headers).with_body(Some(body.into()));
            let req = Request::new_with_init(&url, &init).ok()?;
            Fetch::Request(req).send().await.ok().map(|r| r.status_code())
        }
    });
    match select(Box::pin(join_all(sends)), Delay::from(WEBHOOK_TIMEOUT)).await {
        Either::Left((answers, _)) => {
            for status in answers {
                if !status.is_some_and(|s| (200..300).contains(&s)) {
                    worker::console_warn!("bot webhook answered {status:?}");
                }
            }
        }
        Either::Right(_) => worker::console_warn!("bot webhook didn't answer in time"),
    }
}

/// A webhook address fit to save: https, or http to a local address for testing.
pub fn normalize_webhook(typed: &str) -> Option<String> {
    let url = url::Url::parse(typed.trim()).ok()?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1"));
    (url.scheme() == "https" || (url.scheme() == "http" && local)).then(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_and_webhooks() {
        assert_eq!(statuses(""), Some(&["pending", "approved"][..]));
        assert_eq!(statuses("all"), Some(&[][..]));
        assert_eq!(statuses("added"), Some(&["added"][..]));
        assert_eq!(statuses("downloading"), None);
        assert_eq!(
            normalize_webhook(" https://bot.example/hook?k=1 ").as_deref(),
            Some("https://bot.example/hook?k=1")
        );
        assert_eq!(normalize_webhook("http://127.0.0.1:9000/h").as_deref(), Some("http://127.0.0.1:9000/h"));
        assert_eq!(normalize_webhook("http://bot.example/h"), None);
        assert_eq!(normalize_webhook("not a link"), None);
    }

    fn event(at: i64, level: &str, message: &str) -> BotEvent {
        BotEvent { at, level: level.into(), message: message.into() }
    }

    #[test]
    fn events_are_tidied_ordered_and_capped() {
        let incoming = vec![
            event(200, "error", "  boom  "),
            event(0, "warn", "no time"),
            event(9_999_999, "info", "future"),
            event(150, "info", "   "),
        ];
        let merged = merge_events(vec![event(100, "info", "old")], incoming, 1_000);
        let shown: Vec<_> = merged.iter().map(|e| (e.at, e.level.as_str(), e.message.as_str())).collect();
        assert_eq!(
            shown,
            [(100, "info", "old"), (200, "error", "boom"), (1_000, "info", "no time"), (1_000, "info", "future")]
        );

        let many: Vec<_> = (0..40).map(|i| event(i + 1, "info", "x")).collect();
        assert_eq!(merge_events(vec![], many.clone(), 1_000).len(), EVENTS_PER_REPORT);
        let mut merged = vec![];
        for _ in 0..3 {
            merged = merge_events(merged, many.clone(), 1_000);
        }
        assert_eq!(merged.len(), KEEP_EVENTS);
        assert!(merged.windows(2).all(|w| w[0].at <= w[1].at));

        let long = merge_events(vec![], vec![event(1, "info", &"y".repeat(500))], 10);
        assert_eq!(long[0].message.chars().count(), MAX_TEXT);
    }

    #[test]
    fn signatures_are_hmac_sha256_of_the_body() {
        // echo -n '{"a":1}' | openssl dgst -sha256 -hmac key
        assert_eq!(
            signature("key", r#"{"a":1}"#),
            "sha256=88a67f24bbcdaed0e6c997404bb79a743baf44c6bab2f4c27328e3009d22e342"
        );
    }
}
