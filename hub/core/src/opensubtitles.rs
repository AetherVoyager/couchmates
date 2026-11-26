//! Subtitle search and download on OpenSubtitles.com, for the player's
//! "Search subtitles". Optional: without an API key in Hub Settings the app
//! offers only the free OpenSubtitles add-on's list.
//!
//! The key stays on the Hub. Signing in with an OpenSubtitles account is
//! optional too, but without it downloads count against the Worker's shared
//! address (a handful a day); with it they count against the account (20 a
//! day on a free one).

use couchmates_core::api::{SubtitleDownload, SubtitleResult, SubtitleSearchRequest};
use serde_json::{Value, json};
use worker::{Fetch, Headers, Method, Request, RequestInit};

use crate::store::Store;

pub const KEY: &str = "opensubtitles_key";
pub const USERNAME: &str = "opensubtitles_username";
pub const PASSWORD: &str = "opensubtitles_password";
/// The account's session token from `/login`, and the host it said to use.
pub const TOKEN: &str = "opensubtitles_token";
const HOST: &str = "opensubtitles_host";

const DEFAULT_HOST: &str = "api.opensubtitles.com";
/// OpenSubtitles wants every client to name itself.
const USER_AGENT: &str = "Couchmates v1.0";
const MAX_RESULTS: usize = 60;

pub struct OpenSubtitles {
    key: String,
    username: Option<String>,
    password: Option<String>,
}

type Answer = Result<(u16, Value), String>;

impl OpenSubtitles {
    pub async fn load(store: &Store) -> worker::Result<Option<Self>> {
        let Some(key) = store.setting(KEY).await? else {
            return Ok(None);
        };
        let username = store.setting(USERNAME).await?.filter(|u| !u.is_empty());
        let password = store.setting(PASSWORD).await?.filter(|p| !p.is_empty());
        Ok(Some(Self { key, username, password }))
    }

    pub fn new(key: String, username: Option<String>, password: Option<String>) -> Self {
        Self { key, username, password }
    }

    async fn send(&self, host: &str, method: Method, path: &str, token: Option<&str>, body: Option<&Value>) -> Answer {
        let h = Headers::new();
        let set = |k: &str, v: &str| h.set(k, v).map_err(|e| e.to_string());
        set("api-key", &self.key)?;
        set("user-agent", USER_AGENT)?;
        set("accept", "application/json")?;
        if body.is_some() {
            set("content-type", "application/json")?;
        }
        if let Some(t) = token {
            set("authorization", &format!("Bearer {t}"))?;
        }
        let mut init = RequestInit::new();
        init.with_method(method).with_headers(h);
        if let Some(b) = body {
            init.with_body(Some(b.to_string().into()));
        }
        let url = format!("https://{host}/api/v1{path}");
        let req = Request::new_with_init(&url, &init).map_err(|e| e.to_string())?;
        let mut resp = Fetch::Request(req).send().await.map_err(|e| format!("couldn't reach OpenSubtitles: {e}"))?;
        let status = resp.status_code();
        let text = resp.text().await.unwrap_or_default();
        Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
    }

    /// Signs in with the saved account: the token and the host to use.
    async fn login(&self) -> Result<(String, String), String> {
        let (Some(username), Some(password)) = (&self.username, &self.password) else {
            return Err("no OpenSubtitles account is saved".into());
        };
        let body = json!({ "username": username, "password": password });
        let (status, v) = self.send(DEFAULT_HOST, Method::Post, "/login", None, Some(&body)).await?;
        match status {
            200 => {
                let token = v.get("token").and_then(Value::as_str).ok_or("OpenSubtitles sent no token")?;
                let host = v.get("base_url").and_then(Value::as_str).filter(|h| valid_host(h)).unwrap_or(DEFAULT_HOST);
                Ok((token.to_string(), host.to_string()))
            }
            401 => Err("OpenSubtitles rejected the username or password".into()),
            403 => Err("OpenSubtitles rejected the API key".into()),
            s => Err(format!("OpenSubtitles answered {s} to signing in")),
        }
    }

    /// Checks the key (and the account, when one is given).
    pub async fn test(&self) -> Result<(), String> {
        if self.username.is_some() {
            return self.login().await.map(|_| ());
        }
        match self.send(DEFAULT_HOST, Method::Get, "/infos/formats", None, None).await?.0 {
            200 => Ok(()),
            401 | 403 => Err("OpenSubtitles rejected the API key".into()),
            s => Err(format!("OpenSubtitles answered {s}")),
        }
    }

    pub async fn search(&self, q: &SubtitleSearchRequest) -> Result<Vec<SubtitleResult>, String> {
        let Some(query) = search_query(q) else {
            return Ok(Vec::new());
        };
        let (status, v) = self.send(DEFAULT_HOST, Method::Get, &format!("/subtitles?{query}"), None, None).await?;
        match status {
            200 => Ok(results_from(&v)),
            401 | 403 => Err("OpenSubtitles rejected the Hub's API key".into()),
            429 => Err("OpenSubtitles is busy. Try again in a moment.".into()),
            s => Err(format!("OpenSubtitles answered {s}")),
        }
    }

    /// A temporary link to [file_id]. Signs in (once a day or so) when an
    /// account is saved, so the download counts against it.
    pub async fn download(&self, store: &Store, file_id: u64) -> Result<SubtitleDownload, String> {
        let body = json!({ "file_id": file_id });
        let mut session = self.session(store, false).await;
        let mut answer = self.download_with(&session, &body).await?;
        if answer.0 == 401 && session.0.is_some() {
            session = self.session(store, true).await;
            answer = self.download_with(&session, &body).await?;
        }
        let (status, v) = answer;
        match status {
            200 => download_from(&v).ok_or_else(|| "OpenSubtitles sent no link".to_string()),
            406 | 429 => Err(quota_message(&v)),
            401 | 403 => Err("OpenSubtitles refused the download. Check the key in Hub Settings.".into()),
            404 => Err("That subtitle is gone from OpenSubtitles.".into()),
            s => Err(format!("OpenSubtitles answered {s}")),
        }
    }

    async fn download_with(&self, session: &(Option<String>, String), body: &Value) -> Answer {
        self.send(&session.1, Method::Post, "/download", session.0.as_deref(), Some(body)).await
    }

    /// The saved token and host, signing in for new ones when there are none
    /// (or [fresh]). No account: no token, the default host.
    async fn session(&self, store: &Store, fresh: bool) -> (Option<String>, String) {
        if self.username.is_none() {
            return (None, DEFAULT_HOST.into());
        }
        if !fresh {
            let token = store.setting(TOKEN).await.ok().flatten();
            let host = store.setting(HOST).await.ok().flatten().filter(|h| valid_host(h));
            if let Some(token) = token {
                return (Some(token), host.unwrap_or_else(|| DEFAULT_HOST.into()));
            }
        }
        match self.login().await {
            Ok((token, host)) => {
                let _ = store.set_setting(TOKEN, Some(&token)).await;
                let _ = store.set_setting(HOST, Some(&host)).await;
                (Some(token), host)
            }
            Err(e) => {
                worker::console_warn!("OpenSubtitles sign-in failed: {e}");
                (None, DEFAULT_HOST.into())
            }
        }
    }
}

/// Forgets the account's session, after its details change.
pub async fn forget_session(store: &Store) -> worker::Result<()> {
    store.set_setting(TOKEN, None).await?;
    store.set_setting(HOST, None).await
}

/// Only OpenSubtitles' own API hosts, so a bad answer can't send the key elsewhere.
fn valid_host(h: &str) -> bool {
    h == DEFAULT_HOST
        || (h.ends_with(".opensubtitles.com") && h.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-'))
}

/// OpenSubtitles' language codes for the app's: two letters, except
/// Portuguese and Chinese, which it splits by region.
fn languages(codes: &[String]) -> String {
    let mut out: Vec<String> = Vec::new();
    for c in codes {
        let c = c.trim().to_ascii_lowercase();
        if c.is_empty() || c.len() > 5 || !c.chars().all(|ch| ch.is_ascii_alphabetic() || ch == '-') {
            continue;
        }
        let expanded: &[&str] = match c.as_str() {
            "pt" => &["pt-br", "pt-pt"],
            "zh" => &["zh-cn", "zh-tw"],
            _ => &[],
        };
        if expanded.is_empty() {
            out.push(c);
        } else {
            out.extend(expanded.iter().map(|s| s.to_string()));
        }
    }
    out.sort();
    out.dedup();
    out.join(",")
}

fn imdb_number(id: &str) -> Option<u64> {
    id.strip_prefix("tt").and_then(|n| n.parse().ok())
}

/// The `/subtitles` query for [q], with names in alphabetical order and
/// values lower case, as OpenSubtitles asks (it redirects otherwise). None
/// when there's nothing to search by.
pub fn search_query(q: &SubtitleSearchRequest) -> Option<String> {
    let mut params: Vec<(&str, String)> = Vec::new();
    let imdb = q.imdb.as_deref().and_then(imdb_number);
    let episode = q.season.zip(q.episode);
    match (imdb, episode) {
        (Some(id), Some((season, ep))) => {
            params.push(("parent_imdb_id", id.to_string()));
            params.push(("season_number", season.to_string()));
            params.push(("episode_number", ep.to_string()));
        }
        (Some(id), None) => params.push(("imdb_id", id.to_string())),
        (None, Some((season, ep))) => {
            params.push(("season_number", season.to_string()));
            params.push(("episode_number", ep.to_string()));
        }
        (None, None) => {}
    }
    let query = q.query.as_deref().map(str::trim).filter(|s| !s.is_empty());
    // An id says more than words; words only when there's no id.
    if let (None, Some(words)) = (imdb, query) {
        params.push(("query", words.chars().take(200).collect::<String>().to_lowercase()));
    }
    if let Some(h) = q.hash.as_deref().filter(|h| h.len() == 16 && h.chars().all(|c| c.is_ascii_hexdigit())) {
        params.push(("moviehash", h.to_ascii_lowercase()));
    }
    if imdb.is_none() && query.is_none() && !params.iter().any(|(k, _)| *k == "moviehash") {
        return None;
    }
    let langs = languages(&q.languages);
    if !langs.is_empty() {
        params.push(("languages", langs));
    }
    params.sort_by(|a, b| a.0.cmp(b.0));
    let encoded: Vec<String> = params.iter().map(|(k, v)| format!("{k}={}", encode(v))).collect();
    Some(encoded.join("&"))
}

fn encode(v: &str) -> String {
    url::form_urlencoded::byte_serialize(v.as_bytes()).collect::<String>()
}

/// One result per subtitle file, matches for the file first, then the most
/// downloaded.
pub fn results_from(v: &Value) -> Vec<SubtitleResult> {
    let mut out = Vec::new();
    for item in v.get("data").and_then(Value::as_array).into_iter().flatten() {
        let Some(a) = item.get("attributes") else {
            continue;
        };
        let flag = |k: &str| a.get(k).and_then(Value::as_bool).unwrap_or(false);
        let language = a.get("language").and_then(Value::as_str).unwrap_or("und").to_string();
        let release = a.get("release").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let downloads = a.get("download_count").and_then(Value::as_u64).unwrap_or(0);
        for f in a.get("files").and_then(Value::as_array).into_iter().flatten() {
            let Some(file_id) = f.get("file_id").and_then(Value::as_u64) else {
                continue;
            };
            let file_name = f.get("file_name").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
            out.push(SubtitleResult {
                file_id,
                language: language.clone(),
                release: if release.is_empty() { file_name.clone().unwrap_or_default() } else { release.clone() },
                file_name,
                downloads,
                hearing_impaired: flag("hearing_impaired"),
                machine_translated: flag("machine_translated") || flag("ai_translated"),
                hash_match: flag("moviehash_match"),
            });
        }
    }
    out.sort_by(|a, b| b.hash_match.cmp(&a.hash_match).then(b.downloads.cmp(&a.downloads)));
    out.truncate(MAX_RESULTS);
    out
}

pub fn download_from(v: &Value) -> Option<SubtitleDownload> {
    let url = v.get("link").and_then(Value::as_str)?;
    if !url.starts_with("https://") {
        return None;
    }
    Some(SubtitleDownload {
        url: url.to_string(),
        file_name: v.get("file_name").and_then(Value::as_str).map(str::to_string),
        remaining: v.get("remaining").and_then(Value::as_i64),
    })
}

fn quota_message(v: &Value) -> String {
    let reset = v.get("reset_time").and_then(Value::as_str).map(|t| format!(" It resets in {t}.")).unwrap_or_default();
    format!("The Hub's OpenSubtitles downloads for today are used up.{reset}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(imdb: Option<&str>, se: Option<(u32, u32)>, query: Option<&str>, langs: &[&str]) -> SubtitleSearchRequest {
        SubtitleSearchRequest {
            imdb: imdb.map(str::to_string),
            season: se.map(|s| s.0),
            episode: se.map(|s| s.1),
            query: query.map(str::to_string),
            languages: langs.iter().map(|s| s.to_string()).collect(),
            hash: None,
        }
    }

    #[test]
    fn movie_by_imdb_id() {
        let q = search_query(&req(Some("tt0133093"), None, Some("The Matrix"), &["ml", "en"])).unwrap();
        assert_eq!(q, "imdb_id=133093&languages=en%2Cml");
    }

    #[test]
    fn episode_by_show_id() {
        let mut r = req(Some("tt0903747"), Some((1, 2)), None, &["pt"]);
        r.hash = Some("8E245D9679D31E12".into());
        assert_eq!(
            search_query(&r).unwrap(),
            "episode_number=2&languages=pt-br%2Cpt-pt&moviehash=8e245d9679d31e12&parent_imdb_id=903747&season_number=1"
        );
    }

    #[test]
    fn words_when_there_is_no_id() {
        let q = search_query(&req(None, Some((3, 4)), Some("Some Show"), &[])).unwrap();
        assert_eq!(q, "episode_number=4&query=some+show&season_number=3");
        assert_eq!(search_query(&req(None, None, Some("  "), &["en"])), None);
        assert_eq!(search_query(&req(Some("nope"), None, None, &["en"])), None);
        assert_eq!(languages(&["en".into(), "x;y".into(), "EN".into()]), "en");
    }

    #[test]
    fn results_put_file_matches_first() {
        let v = json!({"data": [
            {"attributes": {"language": "en", "release": "Popular", "download_count": 900,
                "files": [{"file_id": 1, "file_name": "a.srt"}]}},
            {"attributes": {"language": "en", "release": "", "download_count": 5, "moviehash_match": true,
                "hearing_impaired": true, "ai_translated": true, "files": [{"file_id": 2, "file_name": "exact.srt"}]}},
            {"attributes": {"language": "en", "files": []}},
        ]});
        let r = results_from(&v);
        assert_eq!(r.iter().map(|s| s.file_id).collect::<Vec<_>>(), [2, 1]);
        assert!(r[0].hash_match && r[0].hearing_impaired && r[0].machine_translated);
        assert_eq!(r[0].release, "exact.srt");
    }

    #[test]
    fn downloads_need_a_safe_link() {
        let ok = download_from(&json!({"link": "https://dl.opensubtitles.org/x.srt", "remaining": 3})).unwrap();
        assert_eq!(ok.remaining, Some(3));
        assert!(download_from(&json!({"link": "http://evil"})).is_none());
        assert!(valid_host("vip-api.opensubtitles.com"));
        assert!(!valid_host("opensubtitles.com.evil.net"));
        assert!(!valid_host("x.opensubtitles.com/@evil"));
    }
}
