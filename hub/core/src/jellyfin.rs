//! A small, read-only Jellyfin look-alike under `/jellyfin/`, so the admin's
//! Tracearr can follow who watches what on Couchmates.
//!
//! Tracearr adds it as a Jellyfin server (address `<hub>/jellyfin`, the API
//! key from Hub Settings) and polls it. Only what Tracearr reads is answered:
//! the server info and admin check, users and their pictures, sessions (from
//! the app's presence reports), two empty libraries, posters, and empty
//! lists for items, history, activity and plugins. There's no media here, so
//! stopping a stream or sending a message is refused.

use base64::Engine;
use serde_json::{Value, json};
use worker::{Fetch, Headers, Method, Request, RequestInit, Response, Result};

use crate::api::photo_mime;
use crate::crypto::{password_matches, sha256_hex};
use crate::social::{live_any, parse, position_after};
use crate::store::{PresenceRow, Store, User, now};
use crate::web;

/// Where the API key's fingerprint is kept; the key itself is shown once.
pub const KEY_HASH: &str = "jellyfin_key_hash";
/// The server id Tracearr knows the Hub by. Kept when the key is replaced.
pub const SERVER_ID: &str = "jellyfin_server_id";
/// Where Tracearr is pointed.
pub const PREFIX: &str = "/jellyfin";

const SERVER_NAME: &str = "Couchmates";
/// A current Jellyfin version, so Tracearr treats the Hub like one.
const VERSION: &str = "10.11.0";
const TICKS_PER_MS: i64 = 10_000;

/// 32 random hex characters, like a Jellyfin API key or server id.
pub fn new_key() -> String {
    hex::encode(crate::crypto::random_bytes::<16>())
}

/// The key Tracearr sent: `Authorization: MediaBrowser Token="…"` (or
/// `X-Emby-Authorization`), `X-Emby-Token`, `X-MediaBrowser-Token`, or `api_key` in the query.
pub fn sent_key(authorization: Option<&str>, token_header: Option<&str>, query_key: Option<&str>) -> Option<String> {
    let from_auth = authorization.and_then(|h| {
        let rest = h.trim().strip_prefix("MediaBrowser").or_else(|| h.trim().strip_prefix("Emby"))?;
        rest.split(',').find_map(|part| {
            let (k, v) = part.trim().split_once('=')?;
            k.trim().eq_ignore_ascii_case("token").then(|| v.trim().trim_matches('"').to_string())
        })
    });
    from_auth
        .or_else(|| token_header.map(str::to_string))
        .or_else(|| query_key.map(str::to_string))
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
}

// -----------------------------------------------------------------------------
// Ids

/// An item id that carries what it is: hex of `m|<meta id>` for a movie,
/// `s|<meta id>` for a show, `e|<meta id>|<episode>` for an episode. Tracearr
/// takes any id without slashes; hex keeps it safe in a path.
pub fn item_id(kind: char, meta_id: &str, episode: Option<&str>) -> String {
    let key = match episode {
        Some(e) => format!("{kind}|{meta_id}|{e}"),
        None => format!("{kind}|{meta_id}"),
    };
    hex::encode(key.as_bytes())
}

/// The meta id inside an [item_id].
pub fn meta_of(item_id: &str) -> Option<String> {
    let text = String::from_utf8(hex::decode(item_id).ok()?).ok()?;
    let mut parts = text.splitn(3, '|');
    let kind = parts.next()?;
    let meta = parts.next()?;
    (matches!(kind, "m" | "s" | "e") && !meta.is_empty()).then(|| meta.to_string())
}

/// A Hub id as a Jellyfin-style 32-character hex id (Tracearr stores ids as
/// text, but some screens expect a GUID's length).
fn guid(kind: &str, id: &str) -> String {
    sha256_hex(&format!("{kind}:{id}"))[..32].to_string()
}

/// Users are keyed by their Hub id padded into a GUID so the picture route can find them again.
pub fn user_guid(user_id: &str) -> String {
    let hex = hex::encode(user_id.as_bytes());
    if hex.len() >= 32 { hex } else { format!("{hex:0<32}") }
}

/// The Hub id inside a [user_guid].
pub fn user_of(guid: &str) -> Option<String> {
    let trimmed = guid.trim_end_matches('0');
    let even = if trimmed.len() % 2 == 1 { &guid[..trimmed.len() + 1] } else { trimmed };
    String::from_utf8(hex::decode(even).ok()?).ok().filter(|s| !s.is_empty())
}

// -----------------------------------------------------------------------------
// Dates

/// Unix seconds as `2026-11-23T19:19:17.0000000Z`, the way Jellyfin writes dates.
pub fn iso(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.0000000Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

// -----------------------------------------------------------------------------
// Shapes

/// The season, episode number and title in the app's `S1 E3 · Pilot`.
pub fn parse_episode(text: &str) -> (Option<u32>, Option<u32>, Option<String>) {
    let (head, title) = match text.split_once(" · ") {
        Some((h, t)) => (h.trim(), Some(t.trim().to_string())),
        None => (text.trim(), None),
    };
    let numbers = head.strip_prefix('S').and_then(|rest| {
        let (s, e) = rest.split_once(" E")?;
        Some((s.trim().parse().ok()?, e.trim().parse().ok()?))
    });
    match numbers {
        Some((s, e)) => (Some(s), Some(e), title),
        // Not the app's format: the whole text is the title.
        None => (None, None, Some(text.trim().to_string()).filter(|t| !t.is_empty())),
    }
}

fn provider_ids(meta_id: &str) -> Value {
    if meta_id.starts_with("tt") {
        json!({ "Imdb": meta_id })
    } else if let Some(tmdb) = meta_id.strip_prefix("tmdb:") {
        json!({ "Tmdb": tmdb })
    } else {
        json!({})
    }
}

/// Tracearr's poster path for an item, which needs an image tag to exist.
fn image_tag(meta_id: &str) -> String {
    sha256_hex(meta_id)[..32].to_string()
}

/// One device's session, with what it plays when it plays something.
pub fn session(row: &PresenceRow, server_id: &str, now: i64) -> Value {
    let user = user_guid(&row.user_id);
    let mut s = json!({
        "Id": row.device_id,
        "ServerId": server_id,
        "UserId": user,
        "UserName": row.name,
        "Client": "Couchmates",
        "DeviceId": row.device_id,
        "DeviceName": row.device_name.clone().unwrap_or_else(|| "Couchmates".into()),
        "ApplicationVersion": "",
        "RemoteEndPoint": row.ip.clone().unwrap_or_default(),
        "LastActivityDate": iso(row.seen_at),
        "IsActive": true,
        "SupportsMediaControl": false,
        "SupportsRemoteControl": false,
        "PlayableMediaTypes": ["Video"],
    });
    if row.photo_version.is_some() {
        s["UserPrimaryImageTag"] = json!(format!("{}", row.photo_version.unwrap_or(0)));
    }
    let Some(w) = live_any(row, now) else {
        return s;
    };
    let playback = w.playback.clone().unwrap_or_default();
    let position = position_after(&w, now - row.seen_at).unwrap_or(0);
    let episode = w.episode.as_deref().filter(|_| w.meta_type != "movie");
    let id = match episode {
        Some(e) => item_id('e', &w.meta_id, Some(e)),
        None => item_id('m', &w.meta_id, None),
    };
    let mut streams = Vec::new();
    if playback.width.is_some() || playback.video_codec.is_some() {
        streams.push(json!({
            "Type": "Video",
            "Index": 0,
            "Codec": playback.video_codec,
            "Width": playback.width,
            "Height": playback.height,
            "BitRate": playback.bitrate,
            "IsDefault": true,
        }));
    }
    if playback.audio_codec.is_some() {
        streams.push(json!({
            "Type": "Audio",
            "Index": 1,
            "Codec": playback.audio_codec,
            "Channels": playback.audio_channels,
            "IsDefault": true,
        }));
    }
    let mut item = json!({
        "Id": id,
        "ServerId": server_id,
        "Name": w.title,
        "Type": "Movie",
        "MediaType": "Video",
        "ProviderIds": provider_ids(&w.meta_id),
        "ImageTags": { "Primary": image_tag(&w.meta_id) },
        "MediaStreams": streams,
    });
    if let Some(d) = playback.duration_ms {
        item["RunTimeTicks"] = json!(d * TICKS_PER_MS);
    }
    if let Some(e) = episode {
        let (season, number, title) = parse_episode(e);
        item["Type"] = json!("Episode");
        item["Name"] = json!(title.unwrap_or_else(|| e.to_string()));
        item["SeriesName"] = json!(w.title);
        item["SeriesId"] = json!(item_id('s', &w.meta_id, None));
        item["SeriesPrimaryImageTag"] = json!(image_tag(&w.meta_id));
        item["ProviderIds"] = json!({});
        if let Some(s) = season {
            item["ParentIndexNumber"] = json!(s);
            item["SeasonName"] = json!(format!("Season {s}"));
        }
        if let Some(n) = number {
            item["IndexNumber"] = json!(n);
        }
    }
    s["NowPlayingItem"] = item;
    s["PlayState"] = json!({
        "PositionTicks": position * TICKS_PER_MS,
        "CanSeek": true,
        "IsPaused": w.paused,
        "IsMuted": false,
        "PlayMethod": "DirectPlay",
        "MediaSourceId": id,
        "RepeatMode": "RepeatNone",
    });
    s["LastPlaybackCheckIn"] = json!(iso(row.seen_at));
    s
}

/// Sessions for every device that reported in the last minute and a half.
pub fn sessions(rows: &[PresenceRow], server_id: &str, now: i64) -> Value {
    Value::Array(rows.iter().filter(|r| crate::social::online(r, now)).map(|r| session(r, server_id, now)).collect())
}

/// The Hub's users, none of them Jellyfin admins (the API key is the admin).
pub fn users(users: &[User], rows: &[PresenceRow], server_id: &str) -> Value {
    Value::Array(
        users
            .iter()
            .map(|u| {
                let last = rows.iter().filter(|r| r.user_id == u.id).map(|r| r.seen_at).max();
                let mut v = json!({
                    "Id": user_guid(&u.id),
                    // The display name, as sessions give it.
                    "Name": u.name,
                    "ServerId": server_id,
                    "HasPassword": u.password_hash.is_some(),
                    "HasConfiguredPassword": u.password_hash.is_some(),
                    "Policy": {
                        "IsAdministrator": false,
                        "IsDisabled": u.disabled != 0,
                        "IsHidden": false,
                        "EnableAllFolders": true,
                    },
                });
                if let Some(at) = last {
                    v["LastActivityDate"] = json!(iso(at));
                    v["LastLoginDate"] = json!(iso(at));
                }
                if let Some(version) = u.photo_version {
                    v["PrimaryImageTag"] = json!(version.to_string());
                }
                v
            })
            .collect(),
    )
}

pub fn system_info(server_id: &str, address: &str, full: bool) -> Value {
    let mut v = json!({
        "LocalAddress": address,
        "ServerName": SERVER_NAME,
        "Version": VERSION,
        "ProductName": "Jellyfin Server",
        "OperatingSystem": "",
        "Id": server_id,
        "StartupWizardCompleted": true,
    });
    if full {
        v["OperatingSystemDisplayName"] = json!("Cloudflare Workers");
        v["HasPendingRestart"] = json!(false);
        v["IsShuttingDown"] = json!(false);
        v["SupportsLibraryMonitor"] = json!(false);
        v["CanSelfRestart"] = json!(false);
        v["HasUpdateAvailable"] = json!(false);
    }
    v
}

/// Movies and Shows, with nothing in them: Couchmates streams from catalogs.
pub fn libraries() -> Value {
    json!([
        { "Name": "Movies", "CollectionType": "movies", "ItemId": guid("library", "movies"), "Locations": [] },
        { "Name": "Shows", "CollectionType": "tvshows", "ItemId": guid("library", "shows"), "Locations": [] },
    ])
}

fn empty_page() -> Value {
    json!({ "Items": [], "TotalRecordCount": 0, "StartIndex": 0 })
}

/// The poster to show for [meta_id]: one the app reported, else Cinemeta's for an IMDb id.
pub fn poster_for(meta_id: &str, rows: &[PresenceRow]) -> Option<String> {
    let reported = rows
        .iter()
        .filter_map(|r| parse(r.watching.as_deref()))
        .filter(|w| w.meta_id == meta_id)
        .find_map(|w| w.poster);
    reported.or_else(|| {
        let imdb = meta_id.starts_with("tt") && meta_id[2..].chars().all(|c| c.is_ascii_digit()) && meta_id.len() > 2;
        imdb.then(|| format!("https://images.metahub.space/poster/medium/{meta_id}/img"))
    })
}

// -----------------------------------------------------------------------------
// Handler

fn reply(value: &Value) -> Result<Response> {
    web::json(value, 200)
}

fn status(code: u16, message: &str) -> Result<Response> {
    let r = Response::ok(message)?.with_status(code);
    r.headers().set("cache-control", "no-store")?;
    Ok(r)
}

async fn server_id(store: &Store) -> Result<String> {
    Ok(store.setting(SERVER_ID).await?.unwrap_or_else(|| guid("server", "couchmates")))
}

async fn authorized(req: &Request, store: &Store) -> Result<bool> {
    let Some(expected) = store.setting(KEY_HASH).await? else {
        return Ok(false);
    };
    let headers = req.headers();
    let get = |name: &str| headers.get(name).ok().flatten();
    let url = req.url()?;
    let query = url
        .query_pairs()
        .find(|(k, _)| k.eq_ignore_ascii_case("api_key") || k.eq_ignore_ascii_case("apikey"))
        .map(|(_, v)| v.into_owned());
    let auth = get("authorization").or_else(|| get("x-emby-authorization"));
    let token = get("x-emby-token").or_else(|| get("x-mediabrowser-token"));
    Ok(sent_key(auth.as_deref(), token.as_deref(), query.as_deref())
        .is_some_and(|key| password_matches(&sha256_hex(&key), &expected)))
}

/// Everything under `/jellyfin/`. [rest] is the path after the prefix.
pub async fn handle(req: Request, store: &Store, rest: &str) -> Result<Response> {
    let lower = rest.trim_end_matches('/').to_ascii_lowercase();
    let segments: Vec<&str> = lower.trim_start_matches('/').split('/').collect();
    let method = req.method();
    let url = req.url()?;
    let address = format!("{}{PREFIX}", url.origin().ascii_serialization());

    // Answered without a key, like Jellyfin, so Tracearr can tell a bad key from a bad address.
    match (method.clone(), segments.as_slice()) {
        (Method::Get, ["system", "info", "public"]) => {
            return reply(&system_info(&server_id(store).await?, &address, false));
        }
        (Method::Get, ["quickconnect", "enabled"]) => return reply(&json!(false)),
        _ => {}
    }

    if !authorized(&req, store).await? {
        return status(401, "Unauthorized");
    }
    let id = server_id(store).await?;
    let now = now();

    match (method, segments.as_slice()) {
        (Method::Get, ["system", "info"]) => reply(&system_info(&id, &address, true)),
        (Method::Get, ["system", "ping"]) | (Method::Post, ["system", "ping"]) => reply(&json!(SERVER_NAME)),
        // An API key has no user, and Jellyfin answers it with a 400; Tracearr then checks /Auth/Keys.
        (Method::Get, ["users", "me"]) => status(400, "An API key has no user."),
        (Method::Get, ["auth", "keys"]) => reply(&empty_page()),
        (Method::Get, ["users"]) => {
            let rows = store.presence_rows().await?;
            reply(&users(&store.users().await?, &rows, &id))
        }
        (Method::Get, ["users", guid, "images", "primary"]) => {
            let Some(user_id) = user_of(guid) else {
                return status(404, "No picture.");
            };
            user_picture(store, &user_id).await
        }
        (Method::Get, ["users", _, "items"]) => reply(&empty_page()),
        (Method::Get, ["sessions"]) => reply(&sessions(&store.presence_rows().await?, &id, now)),
        (Method::Post, ["sessions", _, "playing", "stop"]) | (Method::Post, ["sessions", _, "message"]) => {
            status(501, "Couchmates can't stop a stream or show a message from here yet.")
        }
        (Method::Get, ["library", "virtualfolders"]) => reply(&libraries()),
        (Method::Get, ["items"]) => reply(&empty_page()),
        (Method::Get, ["items", item, "images", "primary"]) => {
            // The id is hex, so lowercasing the path didn't change it.
            let Some(meta) = meta_of(item) else {
                return status(404, "No poster.");
            };
            let rows = store.presence_rows().await?;
            match poster_for(&meta, &rows) {
                Some(url) => proxy_image(&url).await,
                None => status(404, "No poster."),
            }
        }
        (Method::Get, ["system", "activitylog", "entries"]) => reply(&empty_page()),
        (Method::Get, ["plugins"]) => reply(&json!([])),
        (Method::Post, ["sessions", "logout"]) => status(204, ""),
        _ => status(404, "Not found"),
    }
}

async fn user_picture(store: &Store, user_id: &str) -> Result<Response> {
    let Some((mime, data)) = store.photo(user_id).await? else {
        return status(404, "No picture.");
    };
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
        return status(404, "No picture.");
    };
    image_response(bytes, &mime)
}

fn image_response(bytes: Vec<u8>, mime: &str) -> Result<Response> {
    let response = Response::from_bytes(bytes)?;
    let headers = response.headers();
    headers.set("content-type", mime)?;
    headers.set("cache-control", "private, max-age=86400")?;
    headers.set("x-content-type-options", "nosniff")?;
    headers.set("content-security-policy", "default-src 'none'; sandbox")?;
    Ok(response)
}

/// Fetches a poster and passes it on: Tracearr doesn't follow redirects to other hosts.
async fn proxy_image(url: &str) -> Result<Response> {
    let headers = Headers::new();
    headers.set("accept", "image/*")?;
    let mut init = RequestInit::new();
    init.with_method(Method::Get).with_headers(headers);
    let req = Request::new_with_init(url, &init)?;
    let Ok(mut resp) = Fetch::Request(req).send().await else {
        return status(502, "Couldn't fetch the poster.");
    };
    if resp.status_code() != 200 {
        return status(404, "No poster.");
    }
    let bytes = resp.bytes().await?;
    if bytes.len() > 5 * 1024 * 1024 {
        return status(404, "No poster.");
    }
    let Some(mime) = photo_mime(&bytes) else {
        return status(404, "No poster.");
    };
    image_response(bytes, mime)
}

#[cfg(test)]
mod tests {
    use super::*;
    use couchmates_core::api::{NowWatching, PlaybackInfo};

    fn row(device: &str, user: &str, seen_at: i64, w: Option<NowWatching>) -> PresenceRow {
        PresenceRow {
            device_id: device.into(),
            user_id: user.into(),
            name: user.to_uppercase(),
            seen_at,
            watching: w.map(|w| serde_json::to_string(&w).unwrap()),
            watching_since: Some(seen_at - 100),
            photo_version: None,
            ip: Some("203.0.113.9".into()),
            device_name: Some("Living room PC".into()),
            chat_admin: 0,
            offline: 0,
        }
    }

    fn episode(paused: bool) -> NowWatching {
        NowWatching {
            title: "Severance".into(),
            episode: Some("S1 E3 · In Perpetuity".into()),
            meta_type: "series".into(),
            meta_id: "tt11280740".into(),
            paused,
            room: Some("K7MQ2X".into()),
            poster: None,
            playback: Some(PlaybackInfo {
                position_ms: 60_000,
                duration_ms: Some(3_000_000),
                width: Some(1920),
                height: Some(1080),
                video_codec: Some("hevc".into()),
                audio_codec: Some("eac3".into()),
                audio_channels: Some(6),
                bitrate: Some(8_000_000),
            }),
            private: true,
        }
    }

    #[test]
    fn reads_the_key_wherever_tracearr_puts_it() {
        let auth = r#"MediaBrowser Client="Tracearr", Device="x", DeviceId="y", Version="1", Token="abc123""#;
        assert_eq!(sent_key(Some(auth), None, None).as_deref(), Some("abc123"));
        assert_eq!(sent_key(Some(r#"MediaBrowser Token="k""#), None, None).as_deref(), Some("k"));
        assert_eq!(sent_key(None, Some("t"), None).as_deref(), Some("t"));
        assert_eq!(sent_key(None, None, Some("q")).as_deref(), Some("q"));
        assert_eq!(sent_key(Some("Bearer x"), None, None), None);
    }

    #[test]
    fn ids_carry_the_title_and_the_user() {
        let id = item_id('e', "tt11280740", Some("S1 E3 · In Perpetuity"));
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(meta_of(&id).as_deref(), Some("tt11280740"));
        assert_eq!(meta_of("zz"), None);
        for user in ["a1b2c3d4e5f60708", "x", "0a0", "ab0000"] {
            let g = user_guid(user);
            assert!(g.len() >= 32, "{g}");
            assert_eq!(user_of(&g).as_deref(), Some(user), "{g}");
        }
    }

    #[test]
    fn dates_look_like_jellyfin_dates() {
        assert_eq!(iso(0), "1970-01-01T00:00:00.0000000Z");
        assert_eq!(iso(1_795_461_557), "2026-11-23T19:19:17.0000000Z");
        assert_eq!(iso(951_782_400), "2000-02-29T00:00:00.0000000Z");
    }

    #[test]
    fn episodes_split_into_numbers_and_title() {
        assert_eq!(parse_episode("S1 E3 · Pilot"), (Some(1), Some(3), Some("Pilot".into())));
        assert_eq!(parse_episode("S10 E12"), (Some(10), Some(12), None));
        assert_eq!(parse_episode("Special"), (None, None, Some("Special".into())));
    }

    #[test]
    fn a_playing_episode_becomes_a_jellyfin_session() {
        let now = 10_000;
        let rows = vec![
            row("d1", "bob", now - 10, Some(episode(false))),
            row("d2", "ann", now - 5, None),
            row("d3", "old", now - 500, Some(episode(false))),
        ];
        let all = sessions(&rows, "srv", now);
        let list = all.as_array().unwrap();
        assert_eq!(list.len(), 2, "the stale device is gone");
        let s = &list[0];
        assert_eq!(s["UserName"], "BOB");
        assert_eq!(s["RemoteEndPoint"], "203.0.113.9");
        assert_eq!(s["DeviceName"], "Living room PC");
        let item = &s["NowPlayingItem"];
        assert_eq!(item["Type"], "Episode");
        assert_eq!(item["Name"], "In Perpetuity");
        assert_eq!(item["SeriesName"], "Severance");
        assert_eq!(item["ParentIndexNumber"], 1);
        assert_eq!(item["IndexNumber"], 3);
        assert_eq!(item["RunTimeTicks"], 3_000_000i64 * TICKS_PER_MS);
        assert_eq!(item["MediaStreams"][0]["Width"], 1920);
        // Shared or not, Tracearr sees it, and 10 seconds on, the position has moved.
        assert_eq!(s["PlayState"]["PositionTicks"], 70_000i64 * TICKS_PER_MS);
        assert_eq!(s["PlayState"]["IsPaused"], false);
        assert_eq!(s["PlayState"]["PlayMethod"], "DirectPlay");
        assert!(list[1].get("NowPlayingItem").is_none());
    }

    #[test]
    fn a_movie_has_its_imdb_id() {
        let movie = NowWatching {
            episode: None,
            meta_type: "movie".into(),
            meta_id: "tt1375666".into(),
            title: "Inception".into(),
            ..episode(true)
        };
        let s = session(&row("d", "bob", 100, Some(movie)), "srv", 120);
        assert_eq!(s["NowPlayingItem"]["Type"], "Movie");
        assert_eq!(s["NowPlayingItem"]["ProviderIds"]["Imdb"], "tt1375666");
        assert_eq!(s["PlayState"]["PositionTicks"], 60_000i64 * TICKS_PER_MS, "paused stands still");
    }

    #[test]
    fn posters_come_from_the_app_or_cinemeta() {
        let with_poster =
            NowWatching { poster: Some("https://img/p.jpg".into()), meta_id: "tmdb:1".into(), ..episode(false) };
        let rows = vec![row("d", "bob", 0, Some(with_poster))];
        assert_eq!(poster_for("tmdb:1", &rows).as_deref(), Some("https://img/p.jpg"));
        assert_eq!(poster_for("tt123", &rows).as_deref(), Some("https://images.metahub.space/poster/medium/tt123/img"));
        assert_eq!(poster_for("kitsu:5", &rows), None);
        assert_eq!(poster_for("tt../x", &rows), None);
    }
}
