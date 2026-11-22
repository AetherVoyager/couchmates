//! Telegram-Stremio's admin API, reached the way its web panel does: a form
//! login that sets a `session` cookie, then JSON endpoints under `/api`.
//!
//! These endpoints aren't a published, versioned API, so the shapes read here
//! are kept loose (`serde_json::Value`) and every field is optional.

use serde_json::{Value, json};
use worker::{Fetch, Headers, Method, Request, RequestInit, RequestRedirect, Result};

use crate::store::Store;

pub struct TgsConfig {
    pub base_url: String,
    pub username: String,
    pub password: String,
}

impl TgsConfig {
    pub async fn load(store: &Store) -> Result<Option<Self>> {
        let (Some(base_url), Some(username), Some(password)) = (
            store.setting("tgs_url").await?,
            store.setting("tgs_username").await?,
            store.setting("tgs_password").await?,
        ) else {
            return Ok(None);
        };
        Ok(Some(Self { base_url, username, password }))
    }

    /// The Stremio addon base for a user's access token. Telegram-Stremio
    /// mounts the addon at `/stremio/<token>` (`stremio_routes.py`).
    pub fn addon_base(&self, token: &str) -> String {
        format!("{}/stremio/{}", self.base_url, token)
    }
}

/// [input] as `https://host[:port][/path]` without a trailing `/`.
pub fn normalize_base_url(input: &str) -> Option<String> {
    let url = worker::Url::parse(input.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return None;
    }
    let mut base = format!("{}://{}", url.scheme(), url.host_str()?);
    if let Some(port) = url.port() {
        base.push_str(&format!(":{port}"));
    }
    base.push_str(url.path().trim_end_matches('/'));
    Some(base)
}

pub struct TgsClient<'a> {
    store: &'a Store,
    config: TgsConfig,
    cookie: Option<String>,
}

#[derive(Debug)]
pub enum TgsError {
    NotConfigured,
    LoginFailed(String),
    Http(u16, String),
    Network(String),
}

impl std::fmt::Display for TgsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TgsError::NotConfigured => write!(f, "Telegram-Stremio isn't connected yet"),
            TgsError::LoginFailed(why) => write!(f, "Couldn't sign in to Telegram-Stremio: {why}"),
            TgsError::Http(status, body) => write!(f, "Telegram-Stremio answered {status}: {body}"),
            TgsError::Network(why) => write!(f, "Couldn't reach Telegram-Stremio: {why}"),
        }
    }
}

impl From<worker::Error> for TgsError {
    fn from(e: worker::Error) -> Self {
        TgsError::Network(e.to_string())
    }
}

pub type TgsResult<T> = std::result::Result<T, TgsError>;

fn form_encode(pairs: &[(&str, &str)]) -> String {
    worker::Url::parse("http://x/")
        .map(|mut u| {
            u.query_pairs_mut().extend_pairs(pairs);
            u.query().unwrap_or_default().to_string()
        })
        .unwrap_or_default()
}

/// The `session=...` pair from a login response's `Set-Cookie`.
fn session_cookie(set_cookie: &str) -> Option<String> {
    set_cookie
        .split(|c| c == ',' || c == ';')
        .map(str::trim)
        .find(|part| part.starts_with("session=") && part.len() > "session=".len())
        .map(str::to_string)
}

impl<'a> TgsClient<'a> {
    pub async fn new(store: &'a Store) -> TgsResult<Self> {
        let config = TgsConfig::load(store).await?.ok_or(TgsError::NotConfigured)?;
        let cookie = store.setting("tgs_cookie").await?;
        Ok(Self { store, config, cookie })
    }

    pub fn with_config(store: &'a Store, config: TgsConfig) -> Self {
        Self { store, config, cookie: None }
    }

    pub fn config(&self) -> &TgsConfig {
        &self.config
    }

    /// Signs in with the admin username and password and keeps the cookie.
    pub async fn login(&mut self) -> TgsResult<()> {
        let headers = Headers::new();
        headers.set("content-type", "application/x-www-form-urlencoded")?;
        let body = form_encode(&[("username", &self.config.username), ("password", &self.config.password)]);
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_headers(headers)
            .with_redirect(RequestRedirect::Manual)
            .with_body(Some(body.into()));
        let request = Request::new_with_init(&format!("{}/login", self.config.base_url), &init)?;
        let response = Fetch::Request(request).send().await.map_err(|e| TgsError::Network(e.to_string()))?;
        let status = response.status_code();
        if status == 429 {
            return Err(TgsError::LoginFailed("too many failed attempts; it locks for 15 minutes".into()));
        }
        // A successful login redirects to `/`; a failed one re-renders the form.
        if !(300..400).contains(&status) {
            return Err(TgsError::LoginFailed("wrong username or password".into()));
        }
        let cookie = response
            .headers()
            .get_all("set-cookie")?
            .iter()
            .find_map(|value| session_cookie(value))
            .ok_or_else(|| TgsError::LoginFailed("no session cookie came back".into()))?;
        self.store.set_setting("tgs_cookie", Some(&cookie)).await?;
        self.cookie = Some(cookie);
        Ok(())
    }

    async fn send(&self, method: Method, path: &str, body: Option<&Value>) -> TgsResult<(u16, String)> {
        let headers = Headers::new();
        headers.set("accept", "application/json")?;
        if let Some(cookie) = &self.cookie {
            headers.set("cookie", cookie)?;
        }
        let mut init = RequestInit::new();
        init.with_method(method).with_headers(headers).with_redirect(RequestRedirect::Manual);
        if let Some(body) = body {
            init.headers.set("content-type", "application/json")?;
            init.with_body(Some(body.to_string().into()));
        }
        let request = Request::new_with_init(&format!("{}{}", self.config.base_url, path), &init)?;
        let mut response = Fetch::Request(request).send().await.map_err(|e| TgsError::Network(e.to_string()))?;
        let status = response.status_code();
        let text = response.text().await.unwrap_or_default();
        Ok((status, text))
    }

    /// A GET on the Stremio addon, made the way the app makes it: no admin
    /// cookie, only the token in the path.
    pub async fn addon_get(&self, path: &str) -> TgsResult<(u16, String)> {
        let headers = Headers::new();
        headers.set("accept", "application/json")?;
        let mut init = RequestInit::new();
        init.with_method(Method::Get).with_headers(headers).with_redirect(RequestRedirect::Manual);
        let request = Request::new_with_init(&format!("{}{}", self.config.base_url, path), &init)?;
        let mut response = Fetch::Request(request).send().await.map_err(|e| TgsError::Network(e.to_string()))?;
        let status = response.status_code();
        let text = response.text().await.unwrap_or_default();
        Ok((status, text))
    }

    /// An admin API call, signing in first or again when the session lapsed.
    pub async fn call(&mut self, method: Method, path: &str, body: Option<&Value>) -> TgsResult<Value> {
        if self.cookie.is_none() {
            self.login().await?;
        }
        let (mut status, mut text) = self.send(method.clone(), path, body).await?;
        if status == 401 || (300..400).contains(&status) {
            self.login().await?;
            (status, text) = self.send(method, path, body).await?;
        }
        if !(200..300).contains(&status) {
            let snippet: String = text.chars().take(200).collect();
            return Err(TgsError::Http(status, snippet));
        }
        serde_json::from_str(&text).map_err(|_| TgsError::Http(status, "the answer wasn't JSON".into()))
    }

    /// The public, unauthenticated live stream list.
    pub async fn active_streams(&self) -> TgsResult<Value> {
        let (status, text) = self.send(Method::Get, "/stream/stats", None).await?;
        if !(200..300).contains(&status) {
            return Err(TgsError::Http(status, String::new()));
        }
        serde_json::from_str(&text).map_err(|_| TgsError::Http(status, "the answer wasn't JSON".into()))
    }

    pub async fn system_stats(&mut self) -> TgsResult<Value> {
        self.call(Method::Get, "/api/system/stats", None).await
    }

    pub async fn bot_stats(&mut self) -> TgsResult<Value> {
        self.call(Method::Get, "/api/admin/system-stats", None).await
    }

    /// Creates an access token that never expires on its own: the Hub decides
    /// who has access. Returns the token string.
    pub async fn create_token(&mut self, name: &str, daily_gb: f64, monthly_gb: f64) -> TgsResult<String> {
        let body = json!({
            "name": name,
            "daily_limit_gb": if daily_gb > 0.0 { json!(daily_gb) } else { Value::Null },
            "monthly_limit_gb": if monthly_gb > 0.0 { json!(monthly_gb) } else { Value::Null },
            "subscription_exempt": true,
        });
        let created = self.call(Method::Post, "/api/tokens", Some(&body)).await?;
        created
            .get("token")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| TgsError::Http(200, "no token in the answer".into()))
    }

    /// Telegram-Stremio's own settings (`GET /api/admin/settings`).
    pub async fn admin_settings(&mut self) -> TgsResult<Value> {
        let v = self.call(Method::Get, "/api/admin/settings", None).await?;
        Ok(v.get("settings").cloned().unwrap_or(v))
    }

    /// Whether Telegram-Stremio's "Hide Catalog" is on. It hides catalogs
    /// from every token, not only from unauthenticated users as its panel says.
    pub async fn hide_catalog(&mut self) -> TgsResult<bool> {
        Ok(self.admin_settings().await?.get("hide_catalog").and_then(Value::as_bool).unwrap_or(false))
    }

    /// Turns "Hide Catalog" off. Its panel saves the whole settings object, so
    /// read them all and send them back with only that value changed.
    pub async fn turn_off_hide_catalog(&mut self) -> TgsResult<()> {
        let mut settings = self.admin_settings().await?;
        let Some(map) = settings.as_object_mut() else {
            return Err(TgsError::Http(200, "the settings weren't an object".into()));
        };
        map.insert("hide_catalog".into(), Value::Bool(false));
        self.call(Method::Put, "/api/admin/settings", Some(&settings)).await.map(|_| ())
    }

    pub async fn update_limits(&mut self, token: &str, daily_gb: f64, monthly_gb: f64) -> TgsResult<()> {
        let body = json!({"daily_limit_gb": daily_gb, "monthly_limit_gb": monthly_gb});
        self.call(Method::Put, &format!("/api/tokens/{token}"), Some(&body)).await.map(|_| ())
    }

    pub async fn revoke_token(&mut self, token: &str) -> TgsResult<()> {
        match self.call(Method::Delete, &format!("/api/tokens/{token}"), None).await {
            Ok(_) | Err(TgsError::Http(404, _)) => Ok(()),
            Err(e) => Err(e),
        }
    }
}

/// Usage of one access token, from the system stats' `api_tokens` list.
pub struct TokenUsage {
    pub token: String,
    pub total_bytes: f64,
    pub daily_bytes: f64,
    pub monthly_bytes: f64,
}

pub fn token_usages(system_stats: &Value) -> Vec<TokenUsage> {
    let Some(tokens) = system_stats.get("api_tokens").and_then(Value::as_array) else {
        return Vec::new();
    };
    tokens
        .iter()
        .filter_map(|t| {
            let usage = t.get("usage");
            let num = |v: Option<&Value>| v.and_then(Value::as_f64).unwrap_or(0.0);
            Some(TokenUsage {
                token: t.get("token")?.as_str()?.to_string(),
                total_bytes: num(usage.and_then(|u| u.get("total_bytes"))),
                daily_bytes: num(usage.and_then(|u| u.get("daily")).and_then(|d| d.get("bytes"))),
                monthly_bytes: num(usage.and_then(|u| u.get("monthly")).and_then(|m| m.get("bytes"))),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn addon_base_is_under_stremio() {
        let config =
            TgsConfig { base_url: "https://tg.example.com".into(), username: String::new(), password: String::new() };
        assert_eq!(config.addon_base("abc"), "https://tg.example.com/stremio/abc");
    }

    use super::*;

    #[test]
    fn finds_the_session_cookie() {
        assert_eq!(
            session_cookie("session=abc.def; path=/; Max-Age=1209600; httponly; samesite=lax").as_deref(),
            Some("session=abc.def")
        );
        assert_eq!(session_cookie("theme=dark; path=/"), None);
        assert_eq!(session_cookie("session=; path=/"), None);
    }

    #[test]
    fn normalizes_base_urls() {
        assert_eq!(normalize_base_url("https://TG.example.com/").as_deref(), Some("https://tg.example.com"));
        assert_eq!(normalize_base_url("http://1.2.3.4:8000/sub/").as_deref(), Some("http://1.2.3.4:8000/sub"));
        assert_eq!(normalize_base_url("ftp://x"), None);
        assert_eq!(normalize_base_url("nope"), None);
    }

    #[test]
    fn reads_token_usage() {
        let stats = json!({"api_tokens": [
            {"token": "t1", "usage": {"total_bytes": 10, "daily": {"bytes": 2}, "monthly": {"bytes": 5}}},
            {"token": "t2"},
            {"name": "no token"}
        ]});
        let usages = token_usages(&stats);
        assert_eq!(usages.len(), 2);
        assert_eq!(usages[0].total_bytes, 10.0);
        assert_eq!(usages[0].daily_bytes, 2.0);
        assert_eq!(usages[1].monthly_bytes, 0.0);
    }

    #[test]
    fn form_encodes() {
        assert_eq!(form_encode(&[("username", "a b"), ("password", "p&q=")]), "username=a+b&password=p%26q%3D");
    }
}
