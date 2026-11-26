//! The app API handlers (`/api/app/*`). The request and response shapes live
//! in `couchmates_core::api`, which documents each call.

use couchmates_core::api::{
    AddonInfo, AppConfig, DeviceInfo, DeviceSignOut, ExtraAddon, FileTrack, FileTracks, FileTracksUpload, LoginRequest,
    LoginResponse, OkResponse, PasswordChangeRequest, Profile, ProfilePhotoUpload, ProfileUpdate, ScrobbleRequest,
    SignedInDevice, SubtitleDownloadRequest, SubtitleSearch, SubtitleSearchRequest, TrackerLinkPoll, TrackerLinkStart,
    TrackerRequest, TrackerStatus, TrackersResponse, UpdateDownload, UpdateDownloadRequest, UpdateInfo, UserInfo,
    VoiceInfo, VoiceTokenRequest, VoiceTokenResponse,
};
use couchmates_core::rules::room_for_watch_code;
use worker::{Request, Response, Result};

use crate::addons;
use crate::auth::{hash_password, normalize_username, password_problem, verify_password};
use crate::crypto::random_token;
use crate::livekit::LiveKitConfig;
use crate::opensubtitles::OpenSubtitles;
use crate::store::TrackerLink;
use crate::store::{Device, Store, User, now};
use crate::tgs::TgsConfig;
use crate::tmdb::Tmdb;
use crate::trackers::{self, Keys, Poll};
use crate::updates::{GitHubConfig, is_newer};
use crate::web::{self, json_error};

const LOGIN_WINDOW_SECS: i64 = 15 * 60;
const LOGIN_MAX_FAILS_PER_IP: i64 = 20;
const LOGIN_MAX_FAILS_PER_USER: i64 = 10;
const VOICE_TOKEN_TTL_SECS: i64 = 6 * 3600;

fn user_info(user: &User) -> UserInfo {
    UserInfo {
        id: user.id.clone(),
        name: user.name.clone(),
        username: user.username.clone(),
        photo: photo_path(&user.id, user.photo_version),
    }
}

/// Where the app fetches [user_id]'s picture, when they have one.
pub fn photo_path(user_id: &str, version: Option<i64>) -> Option<String> {
    version.map(|v| format!("{}{user_id}?v={v}", couchmates_core::api::paths::PHOTOS))
}

/// Largest picture the Hub keeps.
pub const MAX_PHOTO_BYTES: usize = 300 * 1024;

/// The image type of [bytes] from its first bytes: JPEG, PNG or WebP.
pub fn photo_mime(bytes: &[u8]) -> Option<&'static str> {
    match bytes {
        [0xFF, 0xD8, 0xFF, ..] => Some("image/jpeg"),
        [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, ..] => Some("image/png"),
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => Some("image/webp"),
        _ => None,
    }
}

pub async fn login(mut req: Request, store: &Store) -> Result<Response> {
    let ip_key = format!("app-ip:{}", web::client_ip(&req));
    if store.recent_failed_logins(&ip_key, LOGIN_WINDOW_SECS).await? >= LOGIN_MAX_FAILS_PER_IP {
        return json_error("Too many attempts. Try again in 15 minutes.", 429);
    }
    let Ok(body) = req.json::<LoginRequest>().await else {
        return json_error("Send a username and password.", 400);
    };
    let wrong = "Wrong username or password.";
    let Some(username) = normalize_username(&body.username) else {
        store.record_failed_login(&ip_key).await?;
        return json_error(wrong, 401);
    };
    let user_key = format!("app-user:{username}");
    if store.recent_failed_logins(&user_key, LOGIN_WINDOW_SECS).await? >= LOGIN_MAX_FAILS_PER_USER {
        return json_error("Too many attempts for this account. Try again in 15 minutes.", 429);
    }
    let user = store.user_by_username(&username).await?;
    let ok = match user.as_ref().and_then(|u| u.password_hash.as_deref()) {
        Some(hash) => verify_password(&body.password, hash).await,
        None => false,
    };
    let (true, Some(user)) = (ok, user) else {
        store.record_failed_login(&ip_key).await?;
        store.record_failed_login(&user_key).await?;
        return json_error(wrong, 401);
    };
    if user.disabled != 0 {
        return json_error("Your access is turned off. Ask the admin.", 403);
    }
    let device_name: String = body
        .device_name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .unwrap_or("Couchmates app")
        .chars()
        .take(60)
        .collect();
    let token = random_token();
    store.create_device(&user.id, &device_name, &token).await?;
    web::json(&LoginResponse { token, user: user_info(&user) }, 200)
}

/// The signed-in device and its user, or the error response to send.
pub async fn authenticate(req: &Request, store: &Store) -> Result<std::result::Result<(Device, User), Response>> {
    let Some(token) = web::bearer(req) else {
        return Ok(Err(json_error("Sign in first.", 401)?));
    };
    let Some(device) = store.device_for_token(&token).await? else {
        return Ok(Err(json_error("This device was signed out. Sign in again.", 401)?));
    };
    let Some(user) = store.user(&device.user_id).await? else {
        return Ok(Err(json_error("This account no longer exists.", 401)?));
    };
    if user.disabled != 0 {
        return Ok(Err(json_error("Your access is turned off. Ask the admin.", 403)?));
    }
    Ok(Ok((device, user)))
}

pub async fn config(req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let addon = match (TgsConfig::load(store).await?, store.user_tgs_token(&user)) {
        (Some(tgs), Some(token)) => {
            let base_url = tgs.addon_base(&token);
            Some(AddonInfo { manifest_url: format!("{base_url}/manifest.json"), base_url })
        }
        _ => None,
    };
    let config = AppConfig {
        user: user_info(&user),
        device: DeviceInfo { id: device.id, name: device.name },
        addon,
        addons: store
            .addons()
            .await?
            .into_iter()
            .filter(|a| a.enabled)
            .map(|a| ExtraAddon { base_url: addons::base_url(&a.manifest_url).to_string(), id: a.id, name: a.name })
            .collect(),
        voice: VoiceInfo { available: crate::voice::available(store).await? },
    };
    web::json(&config, 200)
}

pub async fn voice_token(mut req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<VoiceTokenRequest>().await else {
        return json_error("Send {\"room\": \"<watch party room code>\"}.", 400);
    };
    let Some(room) = room_for_watch_code(&body.room) else {
        return json_error("That isn't a room code.", 400);
    };
    // One identity per device, so the same person on two devices isn't kicked.
    let identity = format!("{}:{}", user.id, device.id);
    if crate::voice::mode(store).await? == couchmates_core::api::voice_mode::DIRECT
        && let Some(relay) = crate::voice::RelayConfig::load(store).await?
    {
        let grant = crate::voice::direct_grant(&relay, &user.id, &identity, &room, VOICE_TOKEN_TTL_SECS);
        return web::json(&grant, 200);
    }
    let Some(livekit) = LiveKitConfig::load(store).await? else {
        return json_error("Voice chat isn't set up on this Hub.", 503);
    };
    let token = livekit.join_token(&identity, &user.name, &room, VOICE_TOKEN_TTL_SECS);
    web::json(
        &VoiceTokenResponse {
            url: livekit.url,
            token,
            room,
            mode: couchmates_core::api::voice_mode::LIVEKIT.to_string(),
            ice_servers: vec![],
            identity: None,
        },
        200,
    )
}

pub async fn change_password(mut req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<PasswordChangeRequest>().await else {
        return json_error("Send the current and new password.", 400);
    };
    let current_ok = match user.password_hash.as_deref() {
        Some(hash) => verify_password(&body.current_password, hash).await,
        None => false,
    };
    if !current_ok {
        return json_error("Your current password is wrong.", 401);
    }
    if let Some(problem) = password_problem(&body.new_password) {
        return json_error(&problem, 400);
    }
    let Ok(hash) = hash_password(&body.new_password).await else {
        return json_error("Couldn't change the password. Try again.", 500);
    };
    store.set_user_password(&user.id, &hash).await?;
    store.delete_devices(&user.id, Some(&device.id)).await?;
    web::json(&OkResponse { ok: true }, 200)
}

pub async fn logout(req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    store.delete_device(&user.id, &device.id).await?;
    web::json(&OkResponse { ok: true }, 200)
}

/// `GET /api/app/update?platform=windows&version=0.1.0`.
pub async fn update(req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let url = req.url()?;
    let query: std::collections::HashMap<String, String> = url.query_pairs().into_owned().collect();
    let platform = query.get("platform").map(String::as_str).unwrap_or("windows");
    let current = query.get("version").map(String::as_str).unwrap_or("0.0.0");
    let none = UpdateInfo { available: false, latest_version: None, newer: false, notes: None, size_bytes: None };
    let Some(github) = GitHubConfig::load(store).await? else {
        return web::json(&none, 200);
    };
    match github.latest(platform).await {
        Ok(Some(release)) => web::json(
            &UpdateInfo {
                available: true,
                newer: is_newer(&release.version, current),
                latest_version: Some(release.version),
                notes: release.notes,
                size_bytes: release.size_bytes,
            },
            200,
        ),
        Ok(None) => web::json(&none, 200),
        Err(e) => json_error(&format!("Couldn't check for updates: {e}"), 502),
    }
}

/// `POST /api/app/update/download` → a short-lived link to the installer.
pub async fn update_download(mut req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let Ok(body) = req.json::<UpdateDownloadRequest>().await else {
        return json_error("Send {\"platform\": \"windows\"}.", 400);
    };
    let Some(github) = GitHubConfig::load(store).await? else {
        return json_error("Updates aren't set up on this Hub.", 503);
    };
    let release = match github.latest(&body.platform).await {
        Ok(Some(r)) => r,
        Ok(None) => {
            return json_error("There's no release with an installer for this platform.", 404);
        }
        Err(e) => return json_error(&format!("Couldn't check for updates: {e}"), 502),
    };
    match github.signed_download_url(&release).await {
        Ok(url) => web::json(&UpdateDownload { url, version: release.version, file_name: release.file_name }, 200),
        Err(e) => json_error(&e, 502),
    }
}

/// `GET /api/app/trackers`: each service, whether it's set up, and linked.
pub async fn trackers(req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let links = store.tracker_links(&user.id).await?;
    let mut list = Vec::new();
    for service in trackers::SERVICES {
        let link = links.iter().find(|l| l.service == service);
        list.push(TrackerStatus {
            service: service.into(),
            available: Keys::load(store, service).await?.is_some(),
            linked: link.is_some(),
            username: link.and_then(|l| l.username.clone()),
        });
    }
    web::json(&TrackersResponse { trackers: list }, 200)
}

async fn tracker_keys(store: &Store, service: &str) -> Result<std::result::Result<Keys, Response>> {
    Ok(match Keys::load(store, service).await? {
        Some(k) => Ok(k),
        None => Err(json_error("That tracker isn't set up on this Hub.", 404)?),
    })
}

/// `POST /api/app/trackers/link`: a code for the user to enter on the site.
pub async fn tracker_link(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<TrackerRequest>().await else {
        return json_error("Send {\"service\": \"trakt\"}.", 400);
    };
    let keys = match tracker_keys(store, &body.service).await? {
        Ok(k) => k,
        Err(r) => return Ok(r),
    };
    match keys.start_link().await {
        Ok(start) => {
            store
                .set_tracker_pending(
                    &user.id,
                    &body.service,
                    &start.device_code,
                    &start.user_code,
                    now() + start.expires_in as i64,
                )
                .await?;
            web::json(
                &TrackerLinkStart {
                    user_code: start.user_code,
                    verification_url: start.verification_url,
                    expires_in: start.expires_in,
                    interval: start.interval,
                },
                200,
            )
        }
        Err(e) => json_error(&e, 502),
    }
}

/// `POST /api/app/trackers/poll`: whether the user has entered the code yet.
pub async fn tracker_poll(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<TrackerRequest>().await else {
        return json_error("Send {\"service\": \"trakt\"}.", 400);
    };
    let keys = match tracker_keys(store, &body.service).await? {
        Ok(k) => k,
        Err(r) => return Ok(r),
    };
    let poll = |status: &str, username: Option<String>| TrackerLinkPoll { status: status.into(), username };
    let Some((device_code, _user_code)) = store.tracker_pending(&user.id, &body.service).await? else {
        return web::json(&poll("expired", None), 200);
    };
    match keys.poll_link(&device_code).await {
        Ok(Poll::Pending) => web::json(&poll("pending", None), 200),
        Ok(Poll::Linked(tokens)) => {
            let username = keys.username(&tokens.access).await;
            let link = TrackerLink {
                service: body.service.clone(),
                access_token: tokens.access,
                refresh_token: tokens.refresh,
                expires_at: tokens.expires_at,
                username: username.clone(),
            };
            store.save_tracker_link(&user.id, &link).await?;
            store.clear_tracker_pending(&user.id, &body.service).await?;
            web::json(&poll("linked", username), 200)
        }
        Ok(Poll::Denied) => {
            store.clear_tracker_pending(&user.id, &body.service).await?;
            web::json(&poll("denied", None), 200)
        }
        Ok(Poll::Expired) => {
            store.clear_tracker_pending(&user.id, &body.service).await?;
            web::json(&poll("expired", None), 200)
        }
        Err(e) => json_error(&e, 502),
    }
}

/// `POST /api/app/trackers/unlink`.
pub async fn tracker_unlink(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<TrackerRequest>().await else {
        return json_error("Send {\"service\": \"trakt\"}.", 400);
    };
    store.delete_tracker_link(&user.id, &body.service).await?;
    store.clear_tracker_pending(&user.id, &body.service).await?;
    web::json(&OkResponse { ok: true }, 200)
}

/// `POST /api/app/scrobble`: forwards to every linked tracker. Failures are
/// logged, not returned: watching shouldn't stop because Trakt is down.
pub async fn scrobble(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<ScrobbleRequest>().await else {
        return json_error("Send a scrobble.", 400);
    };
    if !trackers::valid_scrobble(&body) {
        return json_error("Only movies and episodes with an IMDb id can be scrobbled.", 400);
    }
    for link in store.tracker_links(&user.id).await? {
        let Some(keys) = Keys::load(store, &link.service).await? else {
            continue;
        };
        if let Err(e) = keys.scrobble(store, &user.id, &link, &body).await {
            worker::console_warn!("scrobble to {} failed: {e}", link.service);
        }
    }
    web::json(&OkResponse { ok: true }, 200)
}

/// `GET /api/app/credits?type=movie&tmdb=603&imdb=tt0133093`: cast and crew
/// from TMDB, or `available: false`. Cached by the app's HTTP layer for a day.
pub async fn credits(req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let url = req.url()?;
    let q: std::collections::HashMap<String, String> = url.query_pairs().into_owned().collect();
    let none = crate::tmdb::empty();
    let Some(tmdb) = Tmdb::load(store).await? else {
        return web::json(&none, 200);
    };
    let kind = q.get("type").map(String::as_str).unwrap_or("movie");
    let tmdb_id = q.get("tmdb").and_then(|v| v.parse::<u64>().ok());
    let imdb = q.get("imdb").map(String::as_str).filter(|i| i.starts_with("tt"));
    let response = web::json(&tmdb.credits(kind, tmdb_id, imdb).await, 200)?;
    response.headers().set("cache-control", "private, max-age=86400")?;
    Ok(response)
}

/// `POST /api/app/subtitles/search`: OpenSubtitles' subtitles for a title,
/// or `available: false` when the Hub has no key.
pub async fn subtitle_search(mut req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let Ok(body) = req.json::<SubtitleSearchRequest>().await else {
        return json_error("Send {\"imdb\": \"tt…\", \"languages\": [\"en\"]} or a query.", 400);
    };
    let Some(os) = OpenSubtitles::load(store).await? else {
        return web::json(&SubtitleSearch { available: false, results: Vec::new() }, 200);
    };
    match os.search(&body).await {
        Ok(results) => web::json(&SubtitleSearch { available: true, results }, 200),
        Err(e) => json_error(&format!("{e}."), 502),
    }
}

/// `POST /api/app/subtitles/download`: a temporary link to one subtitle file.
pub async fn subtitle_download(mut req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let Ok(body) = req.json::<SubtitleDownloadRequest>().await else {
        return json_error("Send {\"file_id\": 123}.", 400);
    };
    let Some(os) = OpenSubtitles::load(store).await? else {
        return json_error("Subtitle search isn't set up on the Hub.", 409);
    };
    match os.download(store, body.file_id).await {
        Ok(link) => web::json(&link, 200),
        Err(e) => json_error(&e, 502),
    }
}

async fn profile_of(store: &Store, user: &User, current: &Device) -> Result<Profile> {
    let devices = store
        .devices(&user.id)
        .await?
        .into_iter()
        .map(|d| SignedInDevice {
            current: d.id == current.id,
            id: d.id,
            name: d.name,
            signed_in_at: d.created_at,
            last_seen: d.last_seen,
        })
        .collect();
    Ok(Profile { user: user_info(user), devices })
}

/// `GET /api/app/profile`.
pub async fn profile(req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    web::json(&profile_of(store, &user, &device).await?, 200)
}

/// `POST /api/app/profile`: changes the display name others see.
pub async fn update_profile(mut req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<ProfileUpdate>().await else {
        return json_error("Send {\"name\": \"…\"}.", 400);
    };
    let name: String = body.name.trim().chars().take(60).collect();
    if name.is_empty() {
        return json_error("Your name can't be empty.", 400);
    }
    let username = user.username.clone().unwrap_or_default();
    store.update_user(&user.id, &name, &username, user.daily_limit_gb, user.monthly_limit_gb).await?;
    let updated = User { name, ..user };
    web::json(&profile_of(store, &updated, &device).await?, 200)
}

/// `POST /api/app/profile/photo`: sets the user's picture.
pub async fn upload_photo(mut req: Request, store: &Store) -> Result<Response> {
    use base64::Engine;
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<ProfilePhotoUpload>().await else {
        return json_error("Send {\"image\": \"<base64>\"}.", 400);
    };
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(body.image.trim()) else {
        return json_error("That picture didn't come through. Try again.", 400);
    };
    if bytes.len() > MAX_PHOTO_BYTES {
        return json_error("That picture is too big. Pick a smaller one.", 413);
    }
    let Some(mime) = photo_mime(&bytes) else {
        return json_error("Pictures need to be JPEG, PNG or WebP.", 415);
    };
    let version = store.set_photo(&user.id, mime, &base64::engine::general_purpose::STANDARD.encode(&bytes)).await?;
    let updated = User { photo_version: Some(version), ..user };
    web::json(&profile_of(store, &updated, &device).await?, 200)
}

/// `POST /api/app/profile/photo/remove`.
pub async fn remove_photo(req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    store.delete_photo(&user.id).await?;
    let updated = User { photo_version: None, ..user };
    web::json(&profile_of(store, &updated, &device).await?, 200)
}

/// `GET /api/app/photos/{user_id}`: anyone signed in can see anyone's
/// picture. Cached for good: a new picture gets a new `?v=`.
pub async fn photo(req: Request, store: &Store, user_id: &str) -> Result<Response> {
    use base64::Engine;
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let Some((mime, data)) = store.photo(user_id).await? else {
        return json_error("No picture.", 404);
    };
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
        return json_error("No picture.", 404);
    };
    let response = Response::from_bytes(bytes)?;
    let headers = response.headers();
    headers.set("content-type", &mime)?;
    headers.set("cache-control", "private, max-age=31536000, immutable")?;
    headers.set("x-content-type-options", "nosniff")?;
    headers.set("content-security-policy", "default-src 'none'; sandbox")?;
    Ok(response)
}

/// `POST /api/app/devices/sign-out`: signs out one of the user's own devices.
pub async fn sign_out_device(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<DeviceSignOut>().await else {
        return json_error("Send {\"device_id\": \"…\"}.", 400);
    };
    // Scoped to this user, so nobody can sign out someone else's device.
    store.delete_device(&user.id, &body.device_id).await?;
    web::json(&OkResponse { ok: true }, 200)
}

const MAX_TRACK_KEY: usize = 1024;
const MAX_TRACKS: usize = 64;
const MAX_TRACK_TEXT: usize = 120;

fn track_key_hash(key: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(key.as_bytes()))
}

/// A track list fit to keep, or why not: known kinds, sane numbers, short text.
pub fn clean_tracks(tracks: Vec<FileTrack>) -> std::result::Result<Vec<FileTrack>, &'static str> {
    if tracks.is_empty() || tracks.len() > MAX_TRACKS {
        return Err("Send between 1 and 64 tracks.");
    }
    let short = |v: Option<String>| {
        v.map(|t| t.trim().chars().take(MAX_TRACK_TEXT).collect::<String>()).filter(|t| !t.is_empty())
    };
    tracks
        .into_iter()
        .map(|t| {
            if !matches!(t.kind.as_str(), "video" | "audio" | "subtitle") {
                return Err("A track's kind is video, audio or subtitle.");
            }
            if t.index == 0 || t.index > 999 {
                return Err("A track's index is 1 to 999.");
            }
            Ok(FileTrack {
                codec: short(t.codec),
                language: short(t.language),
                name: short(t.name),
                channels: t.channels.filter(|c| (1..=64).contains(c)),
                width: t.width.filter(|w| (1..=20_000).contains(w)),
                height: t.height.filter(|h| (1..=20_000).contains(h)),
                ..t
            })
        })
        .collect()
}

/// `GET /api/app/tracks?key=…`: a file's tracks, when someone read them.
pub async fn file_tracks(req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let url = req.url()?;
    let key = url.query_pairs().find(|(k, _)| k == "key").map(|(_, v)| v.into_owned()).unwrap_or_default();
    if key.is_empty() || key.len() > MAX_TRACK_KEY {
        return json_error("Send ?key=… naming the file.", 400);
    }
    let tracks = match store.file_tracks(&track_key_hash(&key)).await? {
        Some(json) => serde_json::from_str::<Vec<FileTrack>>(&json).ok(),
        None => None,
    };
    web::json(&FileTracks { tracks }, 200)
}

/// `POST /api/app/tracks`: saves a file's tracks for everyone.
pub async fn save_file_tracks(mut req: Request, store: &Store) -> Result<Response> {
    if let Err(r) = authenticate(&req, store).await? {
        return Ok(r);
    }
    let Ok(body) = req.json::<FileTracksUpload>().await else {
        return json_error("Send {\"key\": \"…\", \"tracks\": [...]}.", 400);
    };
    if body.key.is_empty() || body.key.len() > MAX_TRACK_KEY {
        return json_error("The file key is missing or too long.", 400);
    }
    let tracks = match clean_tracks(body.tracks) {
        Ok(t) => t,
        Err(why) => return json_error(why, 400),
    };
    let json = serde_json::to_string(&tracks).map_err(|e| worker::Error::RustError(e.to_string()))?;
    store.set_file_tracks(&track_key_hash(&body.key), &json).await?;
    web::json(&OkResponse { ok: true }, 200)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(kind: &str, index: u32) -> FileTrack {
        FileTrack {
            kind: kind.into(),
            index,
            codec: Some("  AAC  ".into()),
            language: Some(String::new()),
            name: Some("x".repeat(500)),
            channels: Some(6),
            width: Some(0),
            height: None,
            default: false,
            forced: false,
        }
    }

    #[test]
    fn tracks_are_cleaned_or_refused() {
        let t = clean_tracks(vec![track("audio", 1)]).unwrap();
        assert_eq!(t[0].codec.as_deref(), Some("AAC"));
        assert_eq!(t[0].language, None);
        assert_eq!(t[0].name.as_ref().unwrap().chars().count(), MAX_TRACK_TEXT);
        assert_eq!(t[0].width, None);
        assert_eq!(t[0].channels, Some(6));
        assert!(clean_tracks(vec![]).is_err());
        assert!(clean_tracks(vec![track("data", 1)]).is_err());
        assert!(clean_tracks(vec![track("audio", 0)]).is_err());
        assert!(clean_tracks((1..=65).map(|i| track("audio", i)).collect()).is_err());
    }

    #[test]
    fn track_keys_hash_the_same_way() {
        assert_eq!(track_key_hash("a"), track_key_hash("a"));
        assert_ne!(track_key_hash("a"), track_key_hash("b"));
        assert_eq!(track_key_hash("a").len(), 64);
    }

    #[test]
    fn photo_types_come_from_the_bytes() {
        assert_eq!(photo_mime(&[0xFF, 0xD8, 0xFF, 0xE0, 0]), Some("image/jpeg"));
        assert_eq!(photo_mime(b"\x89PNG\r\n\x1a\nrest"), Some("image/png"));
        assert_eq!(photo_mime(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(photo_mime(b"<svg onload=alert(1)>"), None);
        assert_eq!(photo_mime(b""), None);
        assert_eq!(photo_path("abc", Some(5)).as_deref(), Some("/api/app/photos/abc?v=5"));
        assert_eq!(photo_path("abc", None), None);
    }
}
