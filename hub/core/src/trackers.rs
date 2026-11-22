//! Trakt and Simkl: linking a user's account with a device code (the user
//! types a short code on the service's site) and scrobbling what they watch.
//! The admin registers Couchmates on each service and saves its keys in Hub
//! Settings; tokens are kept per user, sealed, and never reach the app.

use couchmates_core::api::ScrobbleRequest;
use serde_json::{Value, json};
use worker::{Fetch, Headers, Method, Request, RequestInit, Result};

use crate::store::{Store, TrackerLink, now};

pub const SERVICES: [&str; 2] = ["trakt", "simkl"];

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
        let req = Request::new_with_init(&format!("{}{path}", self.base()), &init).map_err(|e| e.to_string())?;
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
            self.call(Method::Get, &format!("/oauth/pin?client_id={}", self.client_id), None, None).await?
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
            verification_url: text("verification_url").unwrap_or_else(|| {
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
    pub async fn poll_link(&self, device_code: &str, user_code: &str) -> std::result::Result<Poll, String> {
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
        let (status, v) =
            self.call(Method::Get, &format!("/oauth/pin/{user_code}?client_id={}", self.client_id), None, None).await?;
        Ok(match (status, v.get("result").and_then(Value::as_str)) {
            (200, Some("OK")) if v.get("access_token").is_some() => Poll::Linked(tokens_from(&v)),
            (200, _) => Poll::Pending,
            _ => Poll::Expired,
        })
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

    /// A fresh access token when Trakt's is about to expire (Simkl's don't).
    async fn refreshed(&self, link: &TrackerLink) -> Option<Tokens> {
        let refresh = link.refresh_token.as_deref()?;
        let body = json!({
            "refresh_token": refresh,
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token",
        });
        let (status, v) = self.call(Method::Post, "/oauth/token", None, Some(&body)).await.ok()?;
        (status == 200).then(|| tokens_from(&v))
    }

    /// Sends one scrobble; refreshes Trakt's token first when needed.
    pub async fn scrobble(
        &self,
        store: &Store,
        user_id: &str,
        link: &TrackerLink,
        s: &ScrobbleRequest,
    ) -> std::result::Result<(), String> {
        let mut token = link.access_token.clone();
        if self.service == "trakt" && link.expires_at.is_some_and(|e| e < now() + 3600) {
            if let Some(t) = self.refreshed(link).await {
                token = t.access.clone();
                let updated = TrackerLink {
                    access_token: t.access,
                    refresh_token: t.refresh,
                    expires_at: t.expires_at,
                    ..link.clone()
                };
                store.save_tracker_link(user_id, &updated).await.map_err(|e| e.to_string())?;
            }
        }
        let (status, _) =
            self.call(Method::Post, &format!("/scrobble/{}", s.action), Some(&token), Some(&scrobble_body(s))).await?;
        // 409: Trakt already has this scrobble (sent twice); that's fine.
        if (200..300).contains(&status) || status == 409 {
            Ok(())
        } else {
            Err(format!("{} answered {status}", self.service))
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

/// Whether [s] is something trackers can take.
pub fn valid_scrobble(s: &ScrobbleRequest) -> bool {
    matches!(s.action.as_str(), "start" | "pause" | "stop")
        && s.imdb.starts_with("tt")
        && s.imdb[2..].chars().all(|c| c.is_ascii_digit())
        && s.imdb.len() > 2
        && (s.kind == "movie" || (s.kind == "episode" && s.season.is_some() && s.episode.is_some()))
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
    fn only_imdb_titles_scrobble() {
        assert!(valid_scrobble(&req("movie", "tt1375666", None, None)));
        assert!(!valid_scrobble(&req("movie", "kitsu:123", None, None)));
        assert!(!valid_scrobble(&req("episode", "tt0903747", Some(1), None)));
        assert!(!valid_scrobble(&ScrobbleRequest { action: "delete".into(), ..req("movie", "tt1", None, None) }));
    }
}
