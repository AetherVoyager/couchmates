//! Title requests: friends search the app for a movie or show that isn't in the library and ask for it, a show
//! one episode at a time. The admin (or their bot) answers on the dashboard's Requests page and adds the title
//! to Telegram-Stremio; the Hub never downloads anything.

use std::collections::HashMap;

pub use couchmates_core::api::request_status;
use couchmates_core::api::{
    MediaRequest, MediaRequestCancel, MediaRequestCreate, MediaRequestEpisodes, MediaRequests, OkResponse,
};
use worker::{Request, Response, Result};

use crate::api::authenticate;
use crate::store::{MediaRequestRow, Store, TitleAsk, User, request_slot};
use crate::web::{self, json_error};

/// Requests one user can be waiting on at once (pending or approved). Each episode counts.
pub const MAX_OPEN_PER_USER: i64 = 500;
/// Most episodes in one [`MediaRequestEpisodes`], which keeps the webhook calls inside a Worker's limits.
pub const MAX_EPISODES_PER_ASK: usize = 40;
const MAX_EPISODE_TITLE: usize = 200;
const MAX_NUMBER: u32 = 10_000;
const MAX_TITLE_ID: usize = 100;
const MAX_NAME: usize = 200;
const MAX_YEAR: usize = 20;
const MAX_POSTER: usize = 600;
/// Longest admin note.
pub const MAX_NOTE: usize = 300;

fn capped(text: &str, max: usize) -> String {
    text.trim().chars().take(max).collect()
}

/// [body] trimmed and capped, with a poster that isn't an https link dropped, or why it can't be asked for.
pub fn clean(body: MediaRequestCreate) -> std::result::Result<MediaRequestCreate, &'static str> {
    if !matches!(body.kind.as_str(), "movie" | "series") {
        return Err("A request is for a movie or a series.");
    }
    let title_id = body.title_id.trim().to_string();
    let id_ok = |c: char| c.is_ascii_alphanumeric() || matches!(c, ':' | '.' | '_' | '-');
    if title_id.is_empty() || title_id.len() > MAX_TITLE_ID || !title_id.chars().all(id_ok) {
        return Err("That title's id isn't one the Hub can keep.");
    }
    let name = capped(&body.name, MAX_NAME);
    if name.is_empty() {
        return Err("Send the title's name.");
    }
    let year = body.year.map(|y| capped(&y, MAX_YEAR)).filter(|y| !y.is_empty());
    let poster = body
        .poster
        .map(|p| p.trim().to_string())
        .filter(|p| p.starts_with("https://") && p.len() <= MAX_POSTER && !p.chars().any(char::is_whitespace));
    let (season, episode, episode_title) = match (body.season, body.episode) {
        (None, None) => (None, None, None),
        (Some(s), Some(e)) => {
            if body.kind != "series" {
                return Err("Only a series has episodes.");
            }
            if s > MAX_NUMBER || e > MAX_NUMBER {
                return Err("That episode number isn't one the Hub can keep.");
            }
            let title = body.episode_title.map(|t| capped(&t, MAX_EPISODE_TITLE)).filter(|t| !t.is_empty());
            (Some(s), Some(e), title)
        }
        _ => return Err("Send both the season and the episode."),
    };
    Ok(MediaRequestCreate { kind: body.kind, title_id, name, year, poster, season, episode, episode_title })
}

/// [body] checked like [clean], as the series it's for and its episodes (duplicates dropped, in order).
pub fn clean_episodes(
    body: MediaRequestEpisodes,
) -> std::result::Result<(MediaRequestCreate, Vec<(u32, u32, Option<String>)>), &'static str> {
    if body.episodes.is_empty() {
        return Err("Send at least one episode.");
    }
    if body.episodes.len() > MAX_EPISODES_PER_ASK {
        return Err("Ask for at most 40 episodes at once.");
    }
    let base = clean(MediaRequestCreate {
        kind: "series".into(),
        title_id: body.title_id,
        name: body.name,
        year: body.year,
        poster: body.poster,
        season: None,
        episode: None,
        episode_title: None,
    })?;
    let mut seen = std::collections::HashSet::new();
    let mut episodes = Vec::new();
    for e in body.episodes {
        if e.season > MAX_NUMBER || e.episode > MAX_NUMBER {
            return Err("That episode number isn't one the Hub can keep.");
        }
        if seen.insert((e.season, e.episode)) {
            let title = e.title.map(|t| capped(&t, MAX_EPISODE_TITLE)).filter(|t| !t.is_empty());
            episodes.push((e.season, e.episode, title));
        }
    }
    Ok((base, episodes))
}

/// The app's view of a stored request.
pub fn to_api(row: MediaRequestRow) -> MediaRequest {
    MediaRequest {
        requested_by: row.requester_names(),
        mine: row.mine != 0,
        id: row.id,
        kind: row.kind,
        title_id: row.title_id,
        name: row.name,
        year: row.year,
        poster: row.poster,
        season: row.season,
        episode: row.episode,
        episode_title: row.episode_title,
        status: row.status,
        note: row.note,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

/// `GET /api/app/requests`: every request, so friends see what's been asked for.
pub async fn list(req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let requests = store.media_requests(&user.id, &[]).await?.into_iter().map(to_api).collect();
    web::json(&MediaRequests { requests }, 200)
}

/// Saves [user]'s ask for [base] (episodes: those of the series, none: the title itself) and tells the bot about
/// the requests that are new or asked for again. Err is the response to send instead.
async fn ask(
    store: &Store,
    user: &User,
    base: &MediaRequestCreate,
    episodes: &[(u32, u32, Option<String>)],
) -> Result<std::result::Result<Vec<MediaRequest>, Response>> {
    let ask = TitleAsk {
        kind: &base.kind,
        title_id: &base.title_id,
        name: &base.name,
        year: base.year.as_deref(),
        poster: base.poster.as_deref(),
        episodes: episodes.iter().map(|(s, e, t)| (*s, *e, t.as_deref())).collect(),
    };
    let slots = ask.slots();
    let before: HashMap<String, String> = store
        .media_requests_for_slots("", &base.kind, &base.title_id, &slots)
        .await?
        .into_iter()
        .map(|r| (request_slot(r.season, r.episode), r.status))
        .collect();
    let fresh = slots.iter().filter(|s| before.get(*s).is_none_or(|st| st != request_status::PENDING)).count() as i64;
    if store.open_requests_of(&user.id).await? + fresh > MAX_OPEN_PER_USER {
        return Ok(Err(json_error(
            "You have 500 requests waiting. Wait for the admin to get through some first.",
            429,
        )?));
    }
    let rows = store.ask_for(&user.id, &ask).await?;
    if rows.is_empty() {
        return Ok(Err(json_error("The request wasn't saved. Try again.", 500)?));
    }
    let requests: Vec<MediaRequest> = rows.into_iter().map(to_api).collect();
    // New, or a declined one asked for again: the bot has something to do.
    let news: Vec<MediaRequest> = requests
        .iter()
        .filter(|r| before.get(&request_slot(r.season, r.episode)).is_none_or(|s| s == request_status::DECLINED))
        .map(|r| MediaRequest { mine: false, ..r.clone() })
        .collect();
    crate::bot::notify(store, &news).await;
    Ok(Ok(requests))
}

/// `POST /api/app/requests`: asks for a movie, a show or one episode, or joins the request there is.
pub async fn create(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<MediaRequestCreate>().await else {
        return json_error("Send {\"kind\": \"movie\", \"title_id\": \"tt…\", \"name\": \"…\"}.", 400);
    };
    let body = match clean(body) {
        Ok(b) => b,
        Err(why) => return json_error(why, 400),
    };
    let episodes: Vec<_> = match (body.season, body.episode) {
        (Some(s), Some(e)) => vec![(s, e, body.episode_title.clone())],
        _ => vec![],
    };
    match ask(store, &user, &body, &episodes).await? {
        Ok(mut requests) => web::json(&requests.remove(0), 200),
        Err(r) => Ok(r),
    }
}

/// `POST /api/app/requests/episodes`: asks for several episodes of a series at once.
pub async fn create_episodes(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<MediaRequestEpisodes>().await else {
        return json_error(
            "Send {\"title_id\": \"tt…\", \"name\": \"…\", \"episodes\": [{\"season\": 1, \"episode\": 1}]}.",
            400,
        );
    };
    let (base, episodes) = match clean_episodes(body) {
        Ok(v) => v,
        Err(why) => return json_error(why, 400),
    };
    match ask(store, &user, &base, &episodes).await? {
        Ok(requests) => web::json(&MediaRequests { requests }, 200),
        Err(r) => Ok(r),
    }
}

/// `POST /api/app/requests/cancel`: takes the user's name off a request.
pub async fn cancel(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<MediaRequestCancel>().await else {
        return json_error("Send {\"id\": \"…\"}.", 400);
    };
    store.withdraw_request(&body.id, &user.id).await?;
    web::json(&OkResponse { ok: true }, 200)
}

/// Most titles checked in one go, to stay well inside a Worker's time.
const MAX_CHECKS: usize = 40;
/// The note a request gets when the Hub finds its title in the library.
pub const FOUND_NOTE: &str = "It's in the library now.";

/// Whether Telegram-Stremio's answer to `/meta/<kind>/<id>.json` is a real title.
pub fn meta_found(body: &serde_json::Value) -> bool {
    body.get("meta").and_then(|m| m.get("id")).and_then(serde_json::Value::as_str).is_some_and(|id| !id.is_empty())
}

fn number(v: Option<&serde_json::Value>) -> Option<u64> {
    let v = v?;
    v.as_u64()
        .or_else(|| v.as_f64().filter(|f| *f >= 0.0 && f.fract() == 0.0).map(|f| f as u64))
        .or_else(|| v.as_str()?.trim().parse().ok())
}

/// The (season, episode) pairs in a meta answer's `videos`: the episodes Telegram-Stremio has files for.
pub fn meta_episodes(body: &serde_json::Value) -> std::collections::HashSet<(u64, u64)> {
    let videos = body.get("meta").and_then(|m| m.get("videos")).and_then(serde_json::Value::as_array);
    videos.into_iter().flatten().filter_map(|v| Some((number(v.get("season"))?, number(v.get("episode"))?))).collect()
}

/// Whether Telegram-Stremio's answer to `/stream/<kind>/<id>.json` has a file to play. Its notices ("Limit
/// Reached", the donation link) come as streams too, without a size or a binge group; the app tells them apart
/// the same way.
pub fn streams_playable(body: &serde_json::Value) -> bool {
    let streams = body.get("streams").and_then(serde_json::Value::as_array);
    streams.into_iter().flatten().any(|s| {
        let url = s.get("url").and_then(serde_json::Value::as_str).unwrap_or("");
        let hints = s.get("behaviorHints");
        (url.starts_with("https://") || url.starts_with("http://"))
            && (s.get("size_bytes").is_some_and(|v| !v.is_null())
                || hints.and_then(|h| h.get("bingeGroup")).is_some_and(|v| !v.is_null()))
    })
}

/// The stream id that tells whether a meta answer is the library's own: the movie itself, or a show's first
/// episode. Telegram-Stremio answers `/meta/` for titles it doesn't have too (with TMDB's or Cinemeta's
/// details, so Stremio can show them), so a real meta alone doesn't mean the title is there.
pub fn probe_id(kind: &str, title_id: &str, body: &serde_json::Value) -> Option<String> {
    if kind != "series" {
        return Some(title_id.to_string());
    }
    let videos = body.get("meta").and_then(|m| m.get("videos")).and_then(serde_json::Value::as_array)?;
    videos.iter().find_map(|v| {
        if let Some(id) = v.get("id").and_then(serde_json::Value::as_str).filter(|id| !id.is_empty()) {
            return Some(id.to_string());
        }
        Some(format!("{title_id}:{}:{}", number(v.get("season"))?, number(v.get("episode"))?))
    })
}

/// Whether [row] is answered by a meta answer: the title is there, and for an episode, that episode too.
pub fn row_found(
    row: &MediaRequestRow,
    body: &serde_json::Value,
    episodes: &std::collections::HashSet<(u64, u64)>,
) -> bool {
    if !meta_found(body) {
        return false;
    }
    match (row.season, row.episode) {
        (Some(s), Some(e)) => episodes.contains(&(s as u64, e as u64)),
        _ => true,
    }
}

/// Marks pending and approved requests Added when Telegram-Stremio has their title (or episode) now, asking it
/// with a user's access token, one call per title. Returns what was marked, as the app names it. Run hourly and
/// from the Requests page; does nothing without a connected server or a user with a token.
pub async fn sync_with_library(store: &Store) -> Result<Vec<String>> {
    let Some(tgs) = crate::tgs::TgsConfig::load(store).await? else {
        return Ok(vec![]);
    };
    let users = store.users().await?;
    let Some(token) = users.iter().filter(|u| u.disabled == 0).find_map(|u| store.user_tgs_token(u)) else {
        return Ok(vec![]);
    };
    let base = tgs.addon_base(&token);
    let open = store.media_requests("", &[request_status::PENDING, request_status::APPROVED]).await?;
    let mut titles: Vec<((String, String), Vec<MediaRequestRow>)> = Vec::new();
    for r in open {
        let key = (r.kind.clone(), r.title_id.clone());
        match titles.iter_mut().find(|(k, _)| *k == key) {
            Some((_, rows)) => rows.push(r),
            None => titles.push((key, vec![r])),
        }
    }
    let mut added = Vec::new();
    for ((kind, title_id), rows) in titles.into_iter().take(MAX_CHECKS) {
        let url = format!("{base}/meta/{kind}/{}.json", crate::addons::path_segment(&title_id));
        let Ok((200, body)) = crate::addons::get_json(&url).await else {
            continue;
        };
        if !meta_found(&body) {
            continue;
        }
        let Some(probe) = probe_id(&kind, &title_id, &body) else {
            continue;
        };
        let url = format!("{base}/stream/{kind}/{}.json", crate::addons::path_segment(&probe));
        match crate::addons::get_json(&url).await {
            Ok((200, streams)) if streams_playable(&streams) => {}
            _ => continue,
        }
        let episodes = meta_episodes(&body);
        for r in rows {
            if row_found(&r, &body, &episodes) {
                let note = r.note.as_deref().unwrap_or(FOUND_NOTE);
                store.set_request_status(&r.id, request_status::ADDED, Some(note)).await?;
                added.push(label(&r.name, r.season, r.episode));
            }
        }
    }
    Ok(added)
}

/// "Breaking Bad S2 E5", or the name alone.
pub fn label(name: &str, season: Option<u32>, episode: Option<u32>) -> String {
    match (season, episode) {
        (Some(s), Some(e)) => format!("{name} S{s} E{e}"),
        _ => name.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(kind: &str, id: &str, name: &str, poster: Option<&str>) -> MediaRequestCreate {
        MediaRequestCreate {
            kind: kind.into(),
            title_id: id.into(),
            name: name.into(),
            year: Some("  1999 ".into()),
            poster: poster.map(str::to_string),
            season: None,
            episode: None,
            episode_title: None,
        }
    }

    #[test]
    fn episodes_are_checked() {
        let mut one = ask("series", "tt1", "Show", None);
        one.season = Some(1);
        one.episode = Some(2);
        one.episode_title = Some("  Pilot ".into());
        let ok = clean(one.clone()).unwrap();
        assert_eq!((ok.season, ok.episode, ok.episode_title.as_deref()), (Some(1), Some(2), Some("Pilot")));
        let mut half = one.clone();
        half.episode = None;
        assert!(clean(half).is_err());
        let mut movie = one.clone();
        movie.kind = "movie".into();
        assert!(clean(movie).is_err());

        use couchmates_core::api::EpisodeAsk;
        let ep = |s, e| EpisodeAsk { season: s, episode: e, title: None };
        let many = |episodes| MediaRequestEpisodes {
            title_id: "tt1".into(),
            name: "Show".into(),
            year: None,
            poster: None,
            episodes,
        };
        let (base, list) = clean_episodes(many(vec![ep(1, 1), ep(1, 2), ep(1, 1)])).unwrap();
        assert_eq!(base.kind, "series");
        assert_eq!(list.iter().map(|(s, e, _)| (*s, *e)).collect::<Vec<_>>(), vec![(1, 1), (1, 2)]);
        assert!(clean_episodes(many(vec![])).is_err());
        assert!(clean_episodes(many((1..=41).map(|e| ep(1, e)).collect())).is_err());
        assert_eq!(label("Show", Some(2), Some(5)), "Show S2 E5");
    }

    #[test]
    fn episodes_in_a_meta() {
        let body = serde_json::json!({"meta": {"id": "tt1", "videos": [
            {"id": "tt1:1:1", "season": 1, "episode": 1},
            {"id": "tt1:1:2", "season": "1", "episode": 2.0},
            {"id": "x"}
        ]}});
        let eps = meta_episodes(&body);
        assert!(eps.contains(&(1, 1)) && eps.contains(&(1, 2)) && eps.len() == 2);
    }

    #[test]
    fn requests_are_cleaned_or_refused() {
        let ok = clean(ask("movie", " tt0133093 ", "  The Matrix ", Some("https://img.example/p.jpg"))).unwrap();
        assert_eq!(ok.title_id, "tt0133093");
        assert_eq!(ok.name, "The Matrix");
        assert_eq!(ok.year.as_deref(), Some("1999"));
        assert_eq!(ok.poster.as_deref(), Some("https://img.example/p.jpg"));
        assert_eq!(clean(ask("series", "kitsu:1", "x", Some("http://img.example/p.jpg"))).unwrap().poster, None);
        assert_eq!(clean(ask("series", "tt1", "x", Some("javascript:alert(1)"))).unwrap().poster, None);
        assert!(clean(ask("channel", "tt1", "x", None)).is_err());
        assert!(clean(ask("movie", "", "x", None)).is_err());
        assert!(clean(ask("movie", "tt1/../x", "x", None)).is_err());
        assert!(clean(ask("movie", "tt1", "   ", None)).is_err());
        assert_eq!(clean(ask("movie", "tt1", &"n".repeat(500), None)).unwrap().name.len(), MAX_NAME);
    }

    #[test]
    fn only_a_file_counts_as_playable() {
        let file = serde_json::json!({"streams": [
            {"name": "1080p", "url": "https://tg.example/dl/t/1/video.mkv", "size_bytes": 5,
             "behaviorHints": {"bingeGroup": "g"}},
            {"name": "Support", "externalUrl": "https://donate.example"}]});
        assert!(streams_playable(&file));
        let donation = serde_json::json!({"streams": [{"name": "Support", "externalUrl": "https://donate.example"}]});
        assert!(!streams_playable(&donation));
        let limit = serde_json::json!({"streams": [{"name": "Limit Reached", "url": "tg://user?id=1"}]});
        assert!(!streams_playable(&limit));
        let expired = serde_json::json!({"streams": [{"name": "Plan Expired", "url": "https://t.me/bot"}]});
        assert!(!streams_playable(&expired));
        assert!(!streams_playable(&serde_json::json!({"streams": []})));
        assert!(!streams_playable(&serde_json::json!({})));
    }

    #[test]
    fn the_probe_is_the_movie_or_a_shows_first_episode() {
        let movie = serde_json::json!({"meta": {"id": "tt1"}});
        assert_eq!(probe_id("movie", "tt1", &movie).as_deref(), Some("tt1"));
        let show = serde_json::json!({"meta": {"id": "tt2", "videos": [
            {"season": 1, "episode": 1}, {"id": "tt2:1:2", "season": 1, "episode": 2}]}});
        assert_eq!(probe_id("series", "tt2", &show).as_deref(), Some("tt2:1:1"));
        let named =
            serde_json::json!({"meta": {"id": "tt2", "videos": [{"id": "tt2:3:4", "season": 3, "episode": 4}]}});
        assert_eq!(probe_id("series", "tt2", &named).as_deref(), Some("tt2:3:4"));
        assert_eq!(probe_id("series", "tt2", &serde_json::json!({"meta": {"id": "tt2", "videos": []}})), None);
    }

    #[test]
    fn only_a_real_meta_counts_as_found() {
        assert!(meta_found(&serde_json::json!({"meta": {"id": "tt1", "name": "x"}})));
        assert!(!meta_found(&serde_json::json!({"meta": null})));
        assert!(!meta_found(&serde_json::json!({})));
        assert!(!meta_found(&serde_json::json!({"meta": {"id": ""}})));
    }
}
