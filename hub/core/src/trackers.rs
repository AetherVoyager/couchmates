//! Trakt and Simkl: linking a user's account with a device code (the user
//! types a short code on the service's site), scrobbling what they watch, and
//! adding or removing what they mark watched in the app.
//! The admin registers Couchmates on each service and saves its keys in Hub
//! Settings; tokens are kept per user, sealed, and never reach the app.

use couchmates_core::api::ScrobbleRequest;
use serde_json::{Value, json};
use worker::{Fetch, Headers, Method, Request, RequestInit, Result};

use crate::store::{Store, TrackerLink, now};

pub const SERVICES: [&str; 2] = ["trakt", "simkl"];

/// What Couchmates asks Simkl for: without `media:write` its tokens are
/// read-only and every scrobble gets 403 `insufficient_scope`.
const SIMKL_SCOPE: &str = "media:read media:write";

/// A service's app keys, from Hub Settings.
pub struct Keys {
    pub service: &'static str,
    pub client_id: String,
    /// Trakt only.
    pub client_secret: Option<String>,
}

impl Keys {
    pub async fn load(store: &Store, service: &str) -> Result<Option<Self>> {
        Ok(match service {
            "trakt" => match (store.setting("trakt_client_id").await?, store.setting("trakt_client_secret").await?) {
                (Some(id), Some(secret)) => Some(Self { service: "trakt", client_id: id, client_secret: Some(secret) }),
                _ => None,
            },
            "simkl" => store.setting("simkl_client_id").await?.map(|id| Self {
                service: "simkl",
                client_id: id,
                client_secret: None,
            }),
            _ => None,
        })
    }

    fn base(&self) -> &'static str {
        if self.service == "trakt" { "https://api.trakt.tv" } else { "https://api.simkl.com" }
    }

    /// [path] on the service. Simkl wants the app named on every call.
    fn url(&self, path: &str) -> String {
        if self.service == "trakt" {
            return format!("{}{path}", self.base());
        }
        let sep = if path.contains('?') { '&' } else { '?' };
        format!(
            "{}{path}{sep}client_id={}&app-name=couchmates&app-version={}",
            self.base(),
            form_encode(&self.client_id),
            env!("CARGO_PKG_VERSION")
        )
    }

    /// A form-encoded POST to Simkl's OAuth 2.0 endpoints, which take forms.
    async fn post_form(&self, path: &str, fields: &[(&str, &str)]) -> std::result::Result<(u16, Value), String> {
        let h = Headers::new();
        let set = |k: &str, v: &str| h.set(k, v).map_err(|e| e.to_string());
        set("content-type", "application/x-www-form-urlencoded")?;
        set("accept", "application/json")?;
        set("user-agent", "Couchmates/0.1")?;
        let body: Vec<String> = fields.iter().map(|(k, v)| format!("{k}={}", form_encode(v))).collect();
        let mut init = RequestInit::new();
        init.with_method(Method::Post).with_headers(h).with_body(Some(body.join("&").into()));
        let req = Request::new_with_init(&format!("{}{path}", self.base()), &init).map_err(|e| e.to_string())?;
        let mut resp = Fetch::Request(req).send().await.map_err(|e| format!("couldn't reach {}: {e}", self.service))?;
        let status = resp.status_code();
        let text = resp.text().await.unwrap_or_default();
        Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
    }

    fn headers(&self, token: Option<&str>) -> Result<Headers> {
        let h = Headers::new();
        h.set("content-type", "application/json")?;
        h.set("accept", "application/json")?;
        h.set("user-agent", "Couchmates/0.1")?;
        if self.service == "trakt" {
            h.set("trakt-api-version", "2")?;
            h.set("trakt-api-key", &self.client_id)?;
        } else {
            h.set("simkl-api-key", &self.client_id)?;
        }
        if let Some(t) = token {
            h.set("authorization", &format!("Bearer {t}"))?;
        }
        Ok(h)
    }

    async fn call(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<&Value>,
    ) -> std::result::Result<(u16, Value), String> {
        let mut init = RequestInit::new();
        init.with_method(method).with_headers(self.headers(token).map_err(|e| e.to_string())?);
        if let Some(b) = body {
            init.with_body(Some(b.to_string().into()));
        }
        let req = Request::new_with_init(&self.url(path), &init).map_err(|e| e.to_string())?;
        let mut resp = Fetch::Request(req).send().await.map_err(|e| format!("couldn't reach {}: {e}", self.service))?;
        let status = resp.status_code();
        let text = resp.text().await.unwrap_or_default();
        Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
    }

    /// Starts linking: the user code and where to enter it, plus the device
    /// code (kept on the Hub) and seconds until it expires.
    pub async fn start_link(&self) -> std::result::Result<LinkStart, String> {
        let (status, v) = if self.service == "trakt" {
            self.call(Method::Post, "/oauth/device/code", None, Some(&json!({ "client_id": self.client_id }))).await?
        } else {
            // Simkl's OAuth 2.0 device flow (RFC 8628). Its older `/oauth/pin`
            // answers 400 for client IDs made since Simkl's OAuth 2.0 apps.
            self.post_form("/oauth2/device", &[("client_id", &self.client_id), ("scope", SIMKL_SCOPE)]).await?
        };
        if !(200..300).contains(&status) {
            return Err(format!(
                "{} refused to start linking ({status}). Check its keys in Hub Settings.",
                self.service
            ));
        }
        let text = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        let num = |k: &str, d: u64| v.get(k).and_then(Value::as_u64).unwrap_or(d);
        Ok(LinkStart {
            device_code: text("device_code").ok_or("no device code in the answer")?,
            user_code: text("user_code").ok_or("no user code in the answer")?,
            verification_url: text("verification_url").or_else(|| text("verification_uri")).unwrap_or_else(|| {
                if self.service == "trakt" {
                    "https://trakt.tv/activate".into()
                } else {
                    "https://simkl.com/pin".into()
                }
            }),
            expires_in: num("expires_in", 600),
            interval: num("interval", 5),
        })
    }

    /// One poll of a link in progress.
    pub async fn poll_link(&self, device_code: &str) -> std::result::Result<Poll, String> {
        if self.service == "trakt" {
            let body = json!({ "code": device_code, "client_id": self.client_id, "client_secret": self.client_secret });
            let (status, v) = self.call(Method::Post, "/oauth/device/token", None, Some(&body)).await?;
            return Ok(match status {
                200 => Poll::Linked(tokens_from(&v)),
                400 | 429 => Poll::Pending,
                418 => Poll::Denied,
                _ => Poll::Expired,
            });
        }
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", device_code),
            ("client_id", self.client_id.as_str()),
        ];
        let (status, v) = self.post_form("/oauth2/token", &fields).await?;
        Ok(simkl_poll(status, &v))
    }

    /// The account name, for showing who's linked.
    pub async fn username(&self, token: &str) -> Option<String> {
        let (status, v) = self.call(Method::Get, "/users/settings", Some(token), None).await.ok()?;
        if status != 200 {
            return None;
        }
        let user = v.get("user")?;
        user.get("username").or_else(|| user.get("name")).and_then(Value::as_str).map(str::to_string)
    }

    /// A fresh access token when the current one is about to expire.
    async fn refreshed(&self, link: &TrackerLink) -> Option<Tokens> {
        let refresh = link.refresh_token.as_deref()?;
        let (status, v) = if self.service == "trakt" {
            let body = json!({
                "refresh_token": refresh,
                "client_id": self.client_id,
                "client_secret": self.client_secret,
                "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
                "grant_type": "refresh_token",
            });
            self.call(Method::Post, "/oauth/token", None, Some(&body)).await.ok()?
        } else {
            let fields =
                [("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", self.client_id.as_str())];
            self.post_form("/oauth2/token", &fields).await.ok()?
        };
        (status == 200).then(|| tokens_from(&v))
    }

    /// Sends one scrobble, or a mark watched / not watched to the history;
    /// refreshes the token first when it's about to expire.
    pub async fn scrobble(
        &self,
        store: &Store,
        user_id: &str,
        link: &TrackerLink,
        s: &ScrobbleRequest,
    ) -> std::result::Result<(), String> {
        let mut token = link.access_token.clone();
        if link.expires_at.is_some_and(|e| e < now() + 3600) {
            if let Some(t) = self.refreshed(link).await {
                token = t.access.clone();
                let updated = TrackerLink {
                    access_token: t.access,
                    // Keep the old refresh token when the answer has none.
                    refresh_token: t.refresh.or_else(|| link.refresh_token.clone()),
                    expires_at: t.expires_at,
                    ..link.clone()
                };
                store.save_tracker_link(user_id, &updated).await.map_err(|e| e.to_string())?;
            }
        }
        let (path, body) = match s.action.as_str() {
            "watched" => ("/sync/history".to_string(), history_body(s)),
            "unwatched" => ("/sync/history/remove".to_string(), history_body(s)),
            action => (format!("/scrobble/{action}"), scrobble_body(s)),
        };
        let (status, v) = self.call(Method::Post, &path, Some(&token), Some(&body)).await?;
        // 409: already scrobbled (sent twice); that's fine.
        if (200..300).contains(&status) || status == 409 {
            Ok(())
        } else {
            let why = v.get("error").and_then(Value::as_str).unwrap_or("no reason given");
            Err(format!("{} answered {status} ({why})", self.service))
        }
    }
}

pub struct LinkStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub expires_in: u64,
    pub interval: u64,
}

pub struct Tokens {
    pub access: String,
    pub refresh: Option<String>,
    pub expires_at: Option<i64>,
}

pub enum Poll {
    Pending,
    Linked(Tokens),
    Expired,
    Denied,
}

/// One answer of Simkl's device token endpoint (RFC 8628 errors).
fn simkl_poll(status: u16, v: &Value) -> Poll {
    let error = v.get("error").and_then(Value::as_str);
    match (status, error) {
        (200, _) if v.get("access_token").and_then(Value::as_str).is_some_and(|t| !t.is_empty()) => {
            Poll::Linked(tokens_from(v))
        }
        (_, Some("authorization_pending" | "slow_down")) | (429, _) => Poll::Pending,
        (_, Some("access_denied")) => Poll::Denied,
        _ => Poll::Expired,
    }
}

fn tokens_from(v: &Value) -> Tokens {
    let created = v.get("created_at").and_then(Value::as_i64).unwrap_or_else(now);
    Tokens {
        access: v.get("access_token").and_then(Value::as_str).unwrap_or_default().to_string(),
        refresh: v.get("refresh_token").and_then(Value::as_str).map(str::to_string),
        expires_at: v.get("expires_in").and_then(Value::as_i64).map(|e| created + e),
    }
}

/// The scrobble body both services take.
pub fn scrobble_body(s: &ScrobbleRequest) -> Value {
    let progress = (s.progress.clamp(0.0, 100.0) * 100.0).round() / 100.0;
    match (s.kind.as_str(), s.season, s.episode) {
        ("episode", Some(season), Some(number)) => json!({
            "progress": progress,
            "show": { "ids": { "imdb": s.imdb } },
            "episode": { "season": season, "number": number },
        }),
        _ => json!({ "progress": progress, "movie": { "ids": { "imdb": s.imdb } } }),
    }
}

/// The history body both services take: a movie, an episode, a whole season
/// (`show` with a season) or a whole show.
pub fn history_body(s: &ScrobbleRequest) -> Value {
    let ids = json!({ "imdb": s.imdb });
    match (s.kind.as_str(), s.season, s.episode) {
        ("episode", Some(season), Some(number)) => json!({
            "shows": [{ "ids": ids, "seasons": [{ "number": season, "episodes": [{ "number": number }] }] }],
        }),
        ("show", Some(season), _) => json!({ "shows": [{ "ids": ids, "seasons": [{ "number": season }] }] }),
        ("show", None, _) => json!({ "shows": [{ "ids": ids }] }),
        _ => json!({ "movies": [{ "ids": ids }] }),
    }
}

/// Whether [s] is something trackers can take.
pub fn valid_scrobble(s: &ScrobbleRequest) -> bool {
    let history = matches!(s.action.as_str(), "watched" | "unwatched");
    (history || matches!(s.action.as_str(), "start" | "pause" | "stop"))
        && s.imdb.starts_with("tt")
        && s.imdb[2..].chars().all(|c| c.is_ascii_digit())
        && s.imdb.len() > 2
        && match s.kind.as_str() {
            "movie" => true,
            "episode" => s.season.is_some() && s.episode.is_some(),
            "show" => history,
            _ => false,
        }
}

/// [v] encoded for a URL query or a form body.
fn form_encode(v: &str) -> String {
    v.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(kind: &str, imdb: &str, season: Option<u32>, episode: Option<u32>) -> ScrobbleRequest {
        ScrobbleRequest {
            action: "start".into(),
            kind: kind.into(),
            imdb: imdb.into(),
            season,
            episode,
            progress: 12.345,
        }
    }

    #[test]
    fn scrobble_bodies() {
        assert_eq!(
            scrobble_body(&req("episode", "tt0903747", Some(1), Some(2))),
            json!({"progress": 12.35, "show": {"ids": {"imdb": "tt0903747"}}, "episode": {"season": 1, "number": 2}})
        );
        assert_eq!(
            scrobble_body(&req("movie", "tt1375666", None, None)),
            json!({"progress": 12.35, "movie": {"ids": {"imdb": "tt1375666"}}})
        );
    }

    #[test]
    fn simkl_device_polls() {
        let pending = json!({"error": "authorization_pending", "error_description": "not yet"});
        assert!(matches!(simkl_poll(400, &pending), Poll::Pending));
        assert!(matches!(simkl_poll(400, &json!({"error": "slow_down"})), Poll::Pending));
        assert!(matches!(simkl_poll(400, &json!({"error": "access_denied"})), Poll::Denied));
        assert!(matches!(simkl_poll(400, &json!({"error": "expired_token"})), Poll::Expired));
        let linked = json!({"access_token": "a", "expires_in": 3600, "refresh_token": "r", "created_at": 1000});
        match simkl_poll(200, &linked) {
            Poll::Linked(t) => {
                assert_eq!((t.access.as_str(), t.refresh.as_deref()), ("a", Some("r")));
                assert_eq!(t.expires_at, Some(4600));
            }
            _ => panic!("expected linked"),
        }
    }

    #[test]
    fn history_bodies() {
        let mark = |kind: &str, season, episode| ScrobbleRequest {
            action: "watched".into(),
            ..req(kind, "tt0903747", season, episode)
        };
        assert_eq!(history_body(&mark("movie", None, None)), json!({"movies": [{"ids": {"imdb": "tt0903747"}}]}));
        assert_eq!(
            history_body(&mark("episode", Some(1), Some(2))),
            json!({"shows": [{"ids": {"imdb": "tt0903747"}, "seasons": [{"number": 1, "episodes": [{"number": 2}]}]}]})
        );
        assert_eq!(
            history_body(&mark("show", Some(3), None)),
            json!({"shows": [{"ids": {"imdb": "tt0903747"}, "seasons": [{"number": 3}]}]})
        );
        assert_eq!(history_body(&mark("show", None, None)), json!({"shows": [{"ids": {"imdb": "tt0903747"}}]}));
        assert!(valid_scrobble(&mark("show", None, None)));
        assert!(!valid_scrobble(&req("show", "tt0903747", None, None)));
    }

    #[test]
    fn forms_encode() {
        assert_eq!(form_encode("media:read media:write"), "media%3Aread%20media%3Awrite");
        assert_eq!(form_encode("abc-123_x.y~"), "abc-123_x.y~");
    }

    #[test]
    fn only_imdb_titles_scrobble() {
        assert!(valid_scrobble(&req("movie", "tt1375666", None, None)));
        assert!(!valid_scrobble(&req("movie", "kitsu:123", None, None)));
        assert!(!valid_scrobble(&req("episode", "tt0903747", Some(1), None)));
        assert!(!valid_scrobble(&ScrobbleRequest { action: "delete".into(), ..req("movie", "tt1", None, None) }));
    }
}
