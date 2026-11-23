//! The bot API (`/api/bot/*`): lets the admin's own program answer title requests. It sends
//! `Authorization: Bearer <bot token>` with the token made on the dashboard's Requests page. The Hub keeps only
//! the token's SHA-256, so a lost token is replaced, not shown again.
//!
//! | Call | Request | Response |
//! |---|---|---|
//! | `GET /api/bot/requests?status=open` | | [`MediaRequests`] |
//! | `POST /api/bot/requests/update` | [`MediaRequestUpdate`] | [`MediaRequest`] |
//!
//! `status` filters by `pending`, `approved`, `added`, `declined`, `open` (pending or approved, the default) or
//! `all`. When a webhook address is saved, a new request (or a declined one asked for again) is also POSTed there
//! as a [`BotWebhook`], signed in `x-couchmates-signature: sha256=<hex HMAC-SHA256 of the body>` keyed with the
//! hex SHA-256 of the bot token.
//!
//! The Hub only records answers. Getting the title is up to the admin's program.

use std::time::Duration;

use couchmates_core::api::{BotWebhook, MediaRequest, MediaRequestUpdate, MediaRequests, request_status};
use futures_util::future::{Either, select};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use worker::{Delay, Fetch, Headers, Method, Request, RequestInit, Response, Result};

use crate::crypto::{password_matches, sha256_hex};
use crate::requests::{MAX_NOTE, to_api};
use crate::store::Store;
use crate::web::{self, json_error};

/// The SHA-256 (hex) of the bot token. Not a secret by itself.
pub const TOKEN_HASH: &str = "bot_token_hash";
/// Where new requests are POSTed. Sealed, since such links often carry a key.
pub const WEBHOOK: &str = "bot_webhook_url";
const WEBHOOK_TIMEOUT: Duration = Duration::from_secs(4);

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

/// The signature header's value for [body].
pub fn signature(token_hash: &str, body: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(token_hash.as_bytes()).expect("HMAC accepts any key length");
    mac.update(body.as_bytes());
    format!("sha256={}", hex::encode(mac.finalize().into_bytes()))
}

/// Tells the bot's webhook about [request], when one is saved. Best effort: a slow or broken webhook never
/// stops a friend's request, and the bot can always catch up with [list].
pub async fn notify(store: &Store, request: &MediaRequest) {
    let (Ok(Some(url)), Ok(Some(token_hash))) = (store.setting(WEBHOOK).await, store.setting(TOKEN_HASH).await) else {
        return;
    };
    let event = BotWebhook { event: "request.created".into(), request: request.clone() };
    let Ok(body) = serde_json::to_string(&event) else {
        return;
    };
    let send = async {
        let headers = Headers::new();
        headers.set("content-type", "application/json").ok()?;
        headers.set("x-couchmates-event", &event.event).ok()?;
        headers.set("x-couchmates-signature", &signature(&token_hash, &body)).ok()?;
        let mut init = RequestInit::new();
        init.with_method(Method::Post).with_headers(headers).with_body(Some(body.clone().into()));
        let req = Request::new_with_init(&url, &init).ok()?;
        Fetch::Request(req).send().await.ok().map(|r| r.status_code())
    };
    match select(Box::pin(send), Delay::from(WEBHOOK_TIMEOUT)).await {
        Either::Left((Some(status), _)) if (200..300).contains(&status) => {}
        Either::Left((status, _)) => worker::console_warn!("bot webhook answered {status:?}"),
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

    #[test]
    fn signatures_are_hmac_sha256_of_the_body() {
        // echo -n '{"a":1}' | openssl dgst -sha256 -hmac key
        assert_eq!(
            signature("key", r#"{"a":1}"#),
            "sha256=88a67f24bbcdaed0e6c997404bb79a743baf44c6bab2f4c27328e3009d22e342"
        );
    }
}
