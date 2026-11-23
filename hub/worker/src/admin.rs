//! The admin dashboard handlers: read the request, do the work with Hub Core,
//! and draw the answer with Hub UI.

use std::collections::HashMap;

use couchmates_hub_core::addons::{self, Report};
use couchmates_hub_core::auth::{
    generated_password, hash_password, new_totp_secret, normalize_username, otpauth_uri, password_problem, qr_svg,
    verify_totp,
};
use couchmates_hub_core::catalog_check::{self, CatalogCheck};
use couchmates_hub_core::crypto::{password_matches, random_token, sha256_hex};
use couchmates_hub_core::livekit::{LiveKitConfig, normalize_server_url};
use couchmates_hub_core::store::{Store, now};
use couchmates_hub_core::tgs::{TgsClient, TgsConfig, normalize_base_url, token_usages};
use couchmates_hub_core::tmdb::Tmdb;
use couchmates_hub_core::updates::{GitHubConfig, normalize_repo};
use couchmates_hub_core::usage::daily_usage;
use couchmates_hub_core::web::{self, Flash};
use couchmates_hub_ui as ui;
use maud::Markup;
use serde_json::Value;
use worker::{Env, Request, Response, Result};

const LOGIN_WINDOW_SECS: i64 = 15 * 60;
const LOGIN_MAX_FAILS: i64 = 10;

fn page(markup: Markup) -> Result<Response> {
    web::html(markup.into_string())
}

fn page_status(markup: Markup, status: u16) -> Result<Response> {
    web::html_status(markup.into_string(), status)
}

fn hub_address(req: &Request) -> Result<String> {
    Ok(req.url()?.origin().ascii_serialization())
}

// -----------------------------------------------------------------------------
// Sign-in

pub enum AdminSession {
    None,
    /// Password checked, two-factor setup still to do.
    NeedsTwoFactorSetup,
    Full,
}

pub async fn session(req: &Request, store: &Store) -> Result<AdminSession> {
    let Some(token) = web::cookie(req, web::SESSION_COOKIE) else {
        return Ok(AdminSession::None);
    };
    Ok(match store.admin_session(&token).await? {
        None => AdminSession::None,
        Some(false) => AdminSession::NeedsTwoFactorSetup,
        Some(true) => AdminSession::Full,
    })
}

pub fn login_page() -> Result<Response> {
    page(ui::sign_in::login(None))
}

/// Accepts [code] for the saved authenticator secret once: a code (time step)
/// that was already used can't sign in again.
async fn accept_totp(store: &Store, secret: &str, code: &str) -> Result<bool> {
    let Some(step) = verify_totp(secret, code, now()) else {
        return Ok(false);
    };
    let last: i64 = store.setting("totp_last_step").await?.and_then(|v| v.parse().ok()).unwrap_or(i64::MIN);
    if step <= last {
        return Ok(false);
    }
    store.set_setting("totp_last_step", Some(&step.to_string())).await?;
    Ok(true)
}

pub async fn login(mut req: Request, env: &Env, store: &Store) -> Result<Response> {
    let ip = web::client_ip(&req);
    if store.recent_failed_logins(&ip, LOGIN_WINDOW_SECS).await? >= LOGIN_MAX_FAILS {
        return page_status(ui::sign_in::login(Some("Too many failed attempts. Try again in 15 minutes.")), 429);
    }
    let Ok(expected) = env.secret("ADMIN_PASSWORD").map(|s| s.to_string()) else {
        return page_status(ui::sign_in::login(Some("ADMIN_PASSWORD isn't set on the Worker.")), 500);
    };
    let form = req.form_data().await?;
    let password = form.get_field("password").unwrap_or_default();
    let code = form.get_field("code").unwrap_or_default();
    let password_ok = !expected.is_empty() && password_matches(&password, &expected);
    let totp_secret = store.setting("totp_secret").await?;
    let full = match (&totp_secret, password_ok) {
        (_, false) => None,
        (Some(secret), true) => accept_totp(store, secret, &code).await?.then_some(true),
        // No authenticator yet: the password alone leads only to setting one up.
        (None, true) => Some(false),
    };
    let Some(full) = full else {
        store.record_failed_login(&ip).await?;
        return page_status(ui::sign_in::login(Some("Wrong password or authenticator code.")), 401);
    };
    let token = random_token();
    store.create_admin_session(&token, web::SESSION_TTL_SECS, full).await?;
    let response = web::redirect(if full { "/" } else { "/setup-2fa" })?;
    response.headers().set("set-cookie", &web::session_cookie_header(&token))?;
    Ok(response)
}

pub async fn logout(req: &Request, store: &Store) -> Result<Response> {
    if let Some(token) = web::cookie(req, web::SESSION_COOKIE) {
        store.delete_admin_session(&token).await?;
    }
    let response = web::redirect("/login")?;
    response.headers().set("set-cookie", &web::clear_session_cookie_header())?;
    Ok(response)
}

/// Two-factor setup: a fresh secret as a QR code, confirmed with a code.
pub async fn setup_2fa_page(store: &Store, error: Option<&str>) -> Result<Response> {
    if store.setting("totp_secret").await?.is_some() {
        return web::redirect("/");
    }
    let secret = match store.setting("totp_pending").await? {
        Some(s) => s,
        None => {
            let s = new_totp_secret();
            store.set_setting("totp_pending", Some(&s)).await?;
            s
        }
    };
    let qr = qr_svg(&otpauth_uri(&secret, "admin"));
    let grouped =
        secret.as_bytes().chunks(4).map(|c| String::from_utf8_lossy(c).into_owned()).collect::<Vec<_>>().join(" ");
    page(ui::sign_in::setup_2fa(&qr, &grouped, error))
}

pub async fn setup_2fa(mut req: Request, store: &Store) -> Result<Response> {
    if store.setting("totp_secret").await?.is_some() {
        return web::redirect("/");
    }
    let code = req.form_data().await?.get_field("code").unwrap_or_default();
    let Some(pending) = store.setting("totp_pending").await? else {
        return web::redirect("/setup-2fa");
    };
    let Some(step) = verify_totp(&pending, &code, now()) else {
        return setup_2fa_page(store, Some("That code didn't match. Check the phone's clock and try the next code."))
            .await;
    };
    store.set_setting("totp_secret", Some(&pending)).await?;
    store.set_setting("totp_pending", None).await?;
    store.set_setting("totp_last_step", Some(&step.to_string())).await?;
    if let Some(token) = web::cookie(&req, web::SESSION_COOKIE) {
        store.mark_admin_session_mfa_ok(&token).await?;
        store.delete_all_admin_sessions_except(&token).await?;
    }
    web::redirect_with("/", true, "Two-factor sign-in is on.")
}

/// Settings → reset: needs a current code, then leads to setting up again.
pub async fn reset_2fa(mut req: Request, store: &Store) -> Result<Response> {
    let code = req.form_data().await?.get_field("code").unwrap_or_default();
    let Some(secret) = store.setting("totp_secret").await? else {
        return web::redirect("/setup-2fa");
    };
    if !accept_totp(store, &secret, &code).await? {
        return web::redirect_with("/settings", false, "That code didn't match, so the authenticator wasn't changed.");
    }
    store.set_setting("totp_secret", None).await?;
    store.set_setting("totp_pending", None).await?;
    let new_token = random_token();
    store.delete_all_admin_sessions_except("").await?;
    store.create_admin_session(&new_token, web::SESSION_TTL_SECS, false).await?;
    let response = web::redirect("/setup-2fa")?;
    response.headers().set("set-cookie", &web::session_cookie_header(&new_token))?;
    Ok(response)
}

// -----------------------------------------------------------------------------
// Overview

pub async fn overview(req: &Request, store: &Store) -> Result<Response> {
    let now = now();
    let users = store.users().await?;
    let active_devices = store.active_device_count(now - 86_400).await?;

    // Telegram-Stremio: library, bots, live streams and per-user usage.
    let mut tgs_error = None;
    let (mut system, mut bots, mut streams) = (Value::Null, Value::Null, Value::Null);
    match TgsClient::new(store).await {
        Ok(mut client) => {
            match client.system_stats().await {
                Ok(v) => system = v,
                Err(e) => tgs_error = Some(e.to_string()),
            }
            if tgs_error.is_none() {
                bots = client.bot_stats().await.unwrap_or(Value::Null);
                streams = client.active_streams().await.unwrap_or(Value::Null);
            }
        }
        Err(e) => tgs_error = Some(e.to_string()),
    }
    let usage_by_token_hash: HashMap<String, (f64, f64)> =
        token_usages(&system).into_iter().map(|u| (sha256_hex(&u.token), (u.daily_bytes, u.monthly_bytes))).collect();
    let live: Vec<&Value> = streams
        .get("active_streams")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter().filter(|s| s.get("status").and_then(Value::as_str).unwrap_or("active") == "active").collect()
        })
        .unwrap_or_default();

    // LiveKit: who is talking right now.
    let voice = match LiveKitConfig::load(store).await? {
        Some(config) => match config.list_rooms().await {
            Ok(rooms) => {
                // Who's in each room, for rooms with people (a few at most).
                let mut detail = Vec::new();
                for r in rooms.iter().filter(|r| r.participants > 0).take(8) {
                    if let Ok(members) = config.list_participants(&r.name).await {
                        detail.push((r.name.clone(), members));
                    }
                }
                ui::overview::VoiceStatus::Rooms {
                    rooms: rooms.len(),
                    people: rooms.iter().map(|r| r.participants).sum(),
                    detail,
                }
            }
            Err(e) => ui::overview::VoiceStatus::Error(e),
        },
        None => ui::overview::VoiceStatus::NotConfigured,
    };

    let history = store.usage_since(now - 8 * 86_400).await?;
    let (week, week_labels) = daily_usage(&history, 7, now);
    let data = ui::overview::Overview {
        users: &users,
        active_devices,
        tgs_error,
        system: &system,
        bots: &bots,
        live,
        voice,
        week,
        week_labels,
        usage_by_token_hash,
        pending_requests: store.pending_request_count().await?,
    };
    page(ui::overview::page(&data, web::flash_from_query(req).as_ref()))
}

// -----------------------------------------------------------------------------
// Users

pub async fn users_page(req: &Request, store: &Store) -> Result<Response> {
    let users = store.users().await?;
    page(ui::users::list(&users, now(), web::flash_from_query(req).as_ref()))
}

struct UserFields {
    name: String,
    username: String,
    password: Option<String>,
    daily: f64,
    monthly: f64,
}

async fn user_fields(req: &mut Request) -> Result<std::result::Result<UserFields, String>> {
    let form = req.form_data().await?;
    let name = form.get_field("name").unwrap_or_default().trim().chars().take(60).collect::<String>();
    if name.is_empty() {
        return Ok(Err("Give the user a display name.".into()));
    }
    let Some(username) = normalize_username(&form.get_field("username").unwrap_or_default()) else {
        return Ok(Err("Usernames are 3 to 32 characters: letters, digits, dots, dashes or underscores.".into()));
    };
    let password = form.get_field("password").map(|p| p.trim().to_string()).filter(|p| !p.is_empty());
    if let Some(problem) = password.as_deref().and_then(password_problem) {
        return Ok(Err(problem));
    }
    Ok(Ok(UserFields {
        name,
        username,
        password,
        daily: web::parse_gb(form.get_field("daily_limit_gb")),
        monthly: web::parse_gb(form.get_field("monthly_limit_gb")),
    }))
}

pub async fn create_user(mut req: Request, store: &Store) -> Result<Response> {
    let fields = match user_fields(&mut req).await? {
        Ok(f) => f,
        Err(e) => return web::redirect_with("/users", false, &e),
    };
    if store.user_by_username(&fields.username).await?.is_some() {
        return web::redirect_with("/users", false, &format!("The username {} is taken.", fields.username));
    }
    let shown_password = fields.password.clone().unwrap_or_else(generated_password);
    let Ok(password_hash) = hash_password(&shown_password).await else {
        return web::redirect_with("/users", false, "Couldn't secure the password. Try again.");
    };
    let mut client = match TgsClient::new(store).await {
        Ok(c) => c,
        Err(e) => return web::redirect_with("/users", false, &e.to_string()),
    };
    let token =
        match client.create_token(&format!("Couchmates: {}", fields.username), fields.daily, fields.monthly).await {
            Ok(t) => t,
            Err(e) => return web::redirect_with("/users", false, &e.to_string()),
        };
    let id = store.create_user(&fields.name, &fields.username, &password_hash, fields.daily, fields.monthly).await?;
    store.set_user_tgs_token(&id, Some(&token)).await?;
    let generated = fields.password.is_none();
    let flash = Flash::Ok(format!("{} was added.", fields.name));
    user_page_with(&req, store, &id, generated.then_some(shown_password), None, Some(flash)).await
}

pub async fn user_page(req: &Request, store: &Store, id: &str) -> Result<Response> {
    user_page_with(req, store, id, None, None, web::flash_from_query(req)).await
}

async fn user_page_with(
    req: &Request,
    store: &Store,
    id: &str,
    new_password: Option<String>,
    check: Option<CatalogCheck>,
    flash: Option<Flash>,
) -> Result<Response> {
    let Some(user) = store.user(id).await? else {
        return web::redirect_with("/users", false, "That user doesn't exist.");
    };
    let devices = store.devices(id).await?;
    let trackers: Vec<(String, Option<String>)> =
        store.tracker_links(id).await?.into_iter().map(|l| (l.service, l.username)).collect();
    let hub = hub_address(req)?;
    let data = ui::users::UserPage {
        user: &user,
        devices: &devices,
        hub: &hub,
        new_password: new_password.as_deref(),
        catalog_check: check.as_ref(),
        trackers: &trackers,
        now: now(),
    };
    page(ui::users::detail(&data, flash.as_ref()))
}

pub async fn user_action(
    mut req: Request,
    store: &Store,
    id: &str,
    action: &str,
    device: Option<&str>,
) -> Result<Response> {
    let Some(user) = store.user(id).await? else {
        return web::redirect_with("/users", false, "That user doesn't exist.");
    };
    let back = format!("/users/{id}");
    let token = store.user_tgs_token(&user);
    match action {
        "update" => {
            let fields = match user_fields(&mut req).await? {
                Ok(f) => f,
                Err(e) => return web::redirect_with(&back, false, &e),
            };
            if let Some(other) = store.user_by_username(&fields.username).await? {
                if other.id != user.id {
                    return web::redirect_with(&back, false, &format!("The username {} is taken.", fields.username));
                }
            }
            if let Some(token) = &token {
                let mut client = match TgsClient::new(store).await {
                    Ok(c) => c,
                    Err(e) => return web::redirect_with(&back, false, &e.to_string()),
                };
                if let Err(e) = client.update_limits(token, fields.daily, fields.monthly).await {
                    return web::redirect_with(&back, false, &e.to_string());
                }
            }
            store.update_user(id, &fields.name, &fields.username, fields.daily, fields.monthly).await?;
            web::redirect_with(&back, true, "Saved.")
        }
        "password" => {
            let typed =
                req.form_data().await?.get_field("password").map(|p| p.trim().to_string()).filter(|p| !p.is_empty());
            if let Some(problem) = typed.as_deref().and_then(password_problem) {
                return web::redirect_with(&back, false, &problem);
            }
            let password = typed.clone().unwrap_or_else(generated_password);
            let Ok(hash) = hash_password(&password).await else {
                return web::redirect_with(&back, false, "Couldn't secure the password. Try again.");
            };
            store.set_user_password(id, &hash).await?;
            store.delete_devices(id, None).await?;
            let shown = if typed.is_some() { None } else { Some(password) };
            let message = if shown.is_some() {
                "New password generated. They're signed out everywhere."
            } else {
                "Password changed. They're signed out everywhere."
            };
            user_page_with(&req, store, id, shown, None, Some(Flash::Ok(message.into()))).await
        }
        "disable" => {
            if let Some(token) = &token {
                match TgsClient::new(store).await {
                    Ok(mut c) => {
                        if let Err(e) = c.revoke_token(token).await {
                            return web::redirect_with(&back, false, &e.to_string());
                        }
                    }
                    Err(e) => return web::redirect_with(&back, false, &e.to_string()),
                }
            }
            store.set_user_tgs_token(id, None).await?;
            store.set_user_disabled(id, true).await?;
            web::redirect_with(&back, true, "Disabled. Their playback stops now.")
        }
        "enable" => {
            let mut client = match TgsClient::new(store).await {
                Ok(c) => c,
                Err(e) => return web::redirect_with(&back, false, &e.to_string()),
            };
            let label = format!("Couchmates: {}", user.username.as_deref().unwrap_or(&user.name));
            match client.create_token(&label, user.daily_limit_gb, user.monthly_limit_gb).await {
                Ok(new_token) => {
                    store.set_user_tgs_token(id, Some(&new_token)).await?;
                    store.set_user_disabled(id, false).await?;
                    web::redirect_with(&back, true, "Enabled.")
                }
                Err(e) => web::redirect_with(&back, false, &e.to_string()),
            }
        }
        "delete" => {
            if let Some(token) = &token {
                if let Ok(mut c) = TgsClient::new(store).await {
                    if let Err(e) = c.revoke_token(token).await {
                        return web::redirect_with(&back, false, &format!("Not deleted: {e}"));
                    }
                }
            }
            store.delete_user(id).await?;
            web::redirect_with("/users", true, &format!("{} was deleted.", user.name))
        }
        "check-catalog" => {
            let Some(token) = &token else {
                return web::redirect_with(&back, false, "This user has no Telegram-Stremio token. Enable them first.");
            };
            let mut client = match TgsClient::new(store).await {
                Ok(c) => c,
                Err(e) => return web::redirect_with(&back, false, &e.to_string()),
            };
            match catalog_check::check(&mut client, token).await {
                Ok(check) => user_page_with(&req, store, id, None, Some(check), None).await,
                Err(e) => web::redirect_with(&back, false, &e.to_string()),
            }
        }
        "device-delete" => {
            if let Some(device) = device {
                store.delete_device(id, device).await?;
            }
            web::redirect_with(&back, true, "That device is signed out.")
        }
        _ => web::redirect(&back),
    }
}

// -----------------------------------------------------------------------------
// Settings

pub async fn settings_page(req: &Request, store: &Store, flash: Option<Flash>) -> Result<Response> {
    let flash = flash.or_else(|| web::flash_from_query(req));
    let tgs_url = store.setting("tgs_url").await?;
    let tgs_username = store.setting("tgs_username").await?;
    let livekit_url = store.setting("livekit_url").await?;
    let livekit_key = store.setting("livekit_key").await?;
    let github_repo = store.setting("github_repo").await?;
    let tgs_hide_catalog = match TgsClient::new(store).await {
        Ok(mut c) => c.hide_catalog().await.ok(),
        Err(_) => None,
    };
    let trakt_client_id = store.setting("trakt_client_id").await?;
    let simkl_client_id = store.setting("simkl_client_id").await?;
    let hub = hub_address(req)?;
    let data = ui::settings::Settings {
        tgs_url: tgs_url.as_deref(),
        tgs_username: tgs_username.as_deref(),
        tgs_has_password: store.setting("tgs_password").await?.is_some(),
        tgs_hide_catalog,
        livekit_url: livekit_url.as_deref(),
        livekit_key: livekit_key.as_deref(),
        livekit_has_secret: store.setting("livekit_secret").await?.is_some(),
        github_repo: github_repo.as_deref(),
        github_has_token: store.setting("github_token").await?.is_some(),
        trakt_client_id: trakt_client_id.as_deref(),
        trakt_has_secret: store.setting("trakt_client_secret").await?.is_some(),
        simkl_client_id: simkl_client_id.as_deref(),
        tmdb_has_key: store.setting("tmdb_key").await?.is_some(),
        hub: &hub,
    };
    page(ui::settings::page(&data, flash.as_ref()))
}

pub async fn save_tgs(mut req: Request, store: &Store) -> Result<Response> {
    let form = req.form_data().await?;
    let Some(url) = form.get_field("url").as_deref().and_then(normalize_base_url) else {
        return settings_page(&req, store, Some(Flash::Bad("Enter the server's http:// or https:// address.".into())))
            .await;
    };
    let username = form.get_field("username").unwrap_or_default().trim().to_string();
    let typed = form.get_field("password").unwrap_or_default();
    let password = if typed.is_empty() { store.setting("tgs_password").await?.unwrap_or_default() } else { typed };
    if username.is_empty() || password.is_empty() {
        return settings_page(&req, store, Some(Flash::Bad("Enter the admin username and password.".into()))).await;
    }
    // Test before saving, so a typo can't break a working setup.
    let config = TgsConfig { base_url: url.clone(), username: username.clone(), password: password.clone() };
    let mut client = TgsClient::with_config(store, config);
    let stats = match client.login().await {
        Ok(()) => client.system_stats().await,
        Err(e) => Err(e),
    };
    match stats {
        Ok(stats) => {
            store.set_setting("tgs_url", Some(&url)).await?;
            store.set_setting("tgs_username", Some(&username)).await?;
            store.set_setting("tgs_password", Some(&password)).await?;
            let version = stats.get("version").and_then(Value::as_str).unwrap_or("unknown version");
            settings_page(&req, store, Some(Flash::Ok(format!("Connected to Telegram-Stremio {version}. Saved."))))
                .await
        }
        Err(e) => {
            store.set_setting("tgs_cookie", None).await?;
            settings_page(&req, store, Some(Flash::Bad(format!("Not saved. {e}")))).await
        }
    }
}

pub async fn save_livekit(mut req: Request, store: &Store) -> Result<Response> {
    let form = req.form_data().await?;
    let Some(url) = form.get_field("url").as_deref().and_then(normalize_server_url) else {
        return settings_page(&req, store, Some(Flash::Bad("Enter a wss:// or https:// LiveKit address.".into())))
            .await;
    };
    let key = form.get_field("key").unwrap_or_default().trim().to_string();
    let typed = form.get_field("secret").unwrap_or_default().trim().to_string();
    let secret = if typed.is_empty() { store.setting("livekit_secret").await?.unwrap_or_default() } else { typed };
    if key.is_empty() || secret.is_empty() {
        return settings_page(&req, store, Some(Flash::Bad("Enter the API key and secret.".into()))).await;
    }
    let config = LiveKitConfig { url: url.clone(), api_key: key.clone(), api_secret: secret.clone() };
    match config.list_rooms().await {
        Ok(rooms) => {
            store.set_setting("livekit_url", Some(&url)).await?;
            store.set_setting("livekit_key", Some(&key)).await?;
            store.set_setting("livekit_secret", Some(&secret)).await?;
            let msg = format!("LiveKit works ({} rooms open right now). Saved.", rooms.len());
            settings_page(&req, store, Some(Flash::Ok(msg))).await
        }
        Err(e) => settings_page(&req, store, Some(Flash::Bad(format!("Not saved: {e}.")))).await,
    }
}

pub async fn save_updates(mut req: Request, store: &Store) -> Result<Response> {
    let form = req.form_data().await?;
    let Some(repo) = form.get_field("repo").as_deref().and_then(normalize_repo) else {
        return settings_page(&req, store, Some(Flash::Bad("Enter the repository as owner/name.".into()))).await;
    };
    let typed = form.get_field("token").unwrap_or_default().trim().to_string();
    let token = if typed.is_empty() { store.setting("github_token").await?.unwrap_or_default() } else { typed };
    if token.is_empty() {
        return settings_page(&req, store, Some(Flash::Bad("Enter a GitHub token.".into()))).await;
    }
    let github = GitHubConfig { repo: repo.clone(), token: token.clone() };
    let found = match github.latest("windows").await {
        Ok(found) => found,
        Err(e) => {
            return settings_page(&req, store, Some(Flash::Bad(format!("Not saved: {e}")))).await;
        }
    };
    store.set_setting("github_repo", Some(&repo)).await?;
    store.set_setting("github_token", Some(&token)).await?;
    let message = match found {
        Some(r) => format!("Saved. Apps will be offered Couchmates {} for Windows.", r.version),
        None => "Saved. There's no versioned release with a Windows installer yet; apps will find one once you tag a release.".into(),
    };
    settings_page(&req, store, Some(Flash::Ok(message))).await
}

pub async fn save_trackers(mut req: Request, store: &Store) -> Result<Response> {
    let form = req.form_data().await?;
    let field = |name: &str| form.get_field(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let trakt_id = field("trakt_client_id");
    let trakt_secret = match field("trakt_client_secret") {
        Some(s) => Some(s),
        None => store.setting("trakt_client_secret").await?,
    };
    if trakt_id.is_some() && trakt_secret.is_none() {
        return settings_page(
            &req,
            store,
            Some(Flash::Bad("Trakt needs both the client ID and the client secret.".into())),
        )
        .await;
    }
    store.set_setting("trakt_client_id", trakt_id.as_deref()).await?;
    store.set_setting("trakt_client_secret", trakt_id.as_ref().and(trakt_secret.as_deref())).await?;
    let simkl_id = field("simkl_client_id");
    store.set_setting("simkl_client_id", simkl_id.as_deref()).await?;
    let on: Vec<&str> =
        [trakt_id.is_some().then_some("Trakt"), simkl_id.is_some().then_some("Simkl")].into_iter().flatten().collect();
    let message = if on.is_empty() {
        "Saved. Trackers are off.".to_string()
    } else {
        format!("Saved. Users can link {} in the app.", on.join(" and "))
    };
    settings_page(&req, store, Some(Flash::Ok(message))).await
}

/// Settings → "Turn off Hide Catalog".
pub async fn show_catalog(req: Request, store: &Store) -> Result<Response> {
    let mut client = match TgsClient::new(store).await {
        Ok(c) => c,
        Err(e) => return settings_page(&req, store, Some(Flash::Bad(e.to_string()))).await,
    };
    let flash = match client.turn_off_hide_catalog().await {
        Ok(()) => Flash::Ok("Hide Catalog is off. The app's home screen will show your catalogs now.".into()),
        Err(e) => {
            Flash::Bad(format!("Couldn't change it: {e}. Untick it in Telegram-Stremio's panel (Settings → General)."))
        }
    };
    settings_page(&req, store, Some(flash)).await
}

pub async fn save_tmdb(mut req: Request, store: &Store) -> Result<Response> {
    let key = req.form_data().await?.get_field("key").unwrap_or_default().trim().to_string();
    if key.is_empty() {
        return settings_page(&req, store, None).await;
    }
    if key.eq_ignore_ascii_case("remove") {
        store.set_setting("tmdb_key", None).await?;
        return settings_page(
            &req,
            store,
            Some(Flash::Ok("TMDB key removed. The app shows the catalog's names.".into())),
        )
        .await;
    }
    match Tmdb::new(key.clone()).test().await {
        Ok(()) => {
            store.set_setting("tmdb_key", Some(&key)).await?;
            settings_page(&req, store, Some(Flash::Ok("TMDB works. Saved: titles now show cast photos.".into()))).await
        }
        Err(e) => settings_page(&req, store, Some(Flash::Bad(format!("Not saved: {e}.")))).await,
    }
}

// -----------------------------------------------------------------------------
// Requests

/// The statuses a Requests filter shows.
fn request_filter(filter: &str) -> &'static [&'static str] {
    use couchmates_hub_core::requests::request_status::*;
    match filter {
        "pending" => &[PENDING],
        "approved" => &[APPROVED],
        "added" => &[ADDED],
        "declined" => &[DECLINED],
        "all" => &[],
        _ => &[PENDING, APPROVED],
    }
}

pub async fn requests_page(req: &Request, store: &Store, flash: Option<Flash>) -> Result<Response> {
    let flash = flash.or_else(|| web::flash_from_query(req));
    let url = req.url()?;
    let asked = url.query_pairs().find(|(k, _)| k == "status").map(|(_, v)| v.into_owned()).unwrap_or_default();
    let filter = ui::requests::FILTERS.iter().map(|(v, _)| *v).find(|v| *v == asked).unwrap_or("open");
    let rows = store.media_requests("", request_filter(filter)).await?;
    let now = now();
    let views: Vec<ui::requests::Request> = rows
        .iter()
        .map(|r| ui::requests::Request {
            id: &r.id,
            kind: &r.kind,
            title_id: &r.title_id,
            name: &r.name,
            year: r.year.as_deref(),
            poster: r.poster.as_deref(),
            status: &r.status,
            note: r.note.as_deref(),
            requested_by: r.requester_names(),
            asked: ui::layout::ago(now, r.created_at),
            changed: ui::layout::ago(now, r.updated_at),
        })
        .collect();
    let pending = store.pending_request_count().await?;
    page(ui::requests::page(&views, filter, pending, flash.as_ref()))
}

/// Requests → a status button (with the note field) or Delete.
pub async fn request_action(mut req: Request, store: &Store, id: &str, action: &str) -> Result<Response> {
    let form = req.form_data().await?;
    let back = form.get_field("back").unwrap_or_default();
    let back = ui::requests::FILTERS.iter().map(|(v, _)| *v).find(|v| *v == back).unwrap_or("open");
    let to = format!("/requests?status={back}");
    let Some(request) = store.media_request(id, "").await? else {
        return web::redirect_with(&to, false, "That request is gone.");
    };
    match action {
        "status" => {
            let status = form.get_field("status").unwrap_or_default();
            if !couchmates_hub_core::requests::request_status::ALL.contains(&status.as_str()) {
                return web::redirect_with(&to, false, "Pick a status.");
            }
            let note: String = form
                .get_field("note")
                .unwrap_or_default()
                .trim()
                .chars()
                .take(couchmates_hub_core::requests::MAX_NOTE)
                .collect();
            store.set_request_status(id, &status, (!note.is_empty()).then_some(note.as_str())).await?;
            let message = format!("{} is {}.", request.name, ui::requests::status_label(&status).to_lowercase());
            web::redirect_with(&to, true, &message)
        }
        "delete" => {
            store.delete_request(id).await?;
            web::redirect_with(&to, true, &format!("Deleted the request for {}.", request.name))
        }
        _ => web::redirect(&to),
    }
}

// -----------------------------------------------------------------------------
// Add-ons

pub async fn addons_page(req: &Request, store: &Store, flash: Option<Flash>) -> Result<Response> {
    let flash = flash.or_else(|| web::flash_from_query(req));
    let rows = store.addons().await?;
    let now = now();
    let parsed: Vec<(Report, Value)> = rows
        .iter()
        .map(|a| {
            let report = serde_json::from_str(&a.report)
                .unwrap_or_else(|_| addons::unreadable("No saved check. Check it again."));
            (report, serde_json::from_str(&a.manifest).unwrap_or(Value::Null))
        })
        .collect();
    let views: Vec<ui::addons::Addon> = rows
        .iter()
        .zip(&parsed)
        .map(|(a, (report, manifest))| ui::addons::Addon {
            id: &a.id,
            name: &a.name,
            version: manifest.get("version").and_then(Value::as_str).unwrap_or(""),
            description: manifest.get("description").and_then(Value::as_str).filter(|d| !d.is_empty()),
            manifest_url: &a.manifest_url,
            enabled: a.enabled,
            report,
            checked: ui::layout::ago(now, a.checked_at),
        })
        .collect();
    let suggestions: Vec<&ui::addons::Suggestion> =
        ui::addons::SUGGESTIONS.iter().filter(|s| !rows.iter().any(|a| a.manifest_url == s.manifest_url)).collect();
    page(ui::addons::page(&views, &suggestions, flash.as_ref()))
}

/// Add-ons → "Check and add": reads the manifest, runs the check, and adds
/// it, turned on unless nothing in it works with the app.
pub async fn add_addon(mut req: Request, store: &Store) -> Result<Response> {
    let typed = req.form_data().await?.get_field("url").unwrap_or_default();
    let Some(url) = addons::normalize_manifest_url(&typed) else {
        return addons_page(&req, store, Some(Flash::Bad("Paste the add-on's https://…/manifest.json link.".into())))
            .await;
    };
    if store.addon_exists(&url).await? {
        return addons_page(&req, store, Some(Flash::Bad("That add-on is already on the list.".into()))).await;
    }
    let manifest = match addons::fetch_manifest(&url).await {
        Ok(m) => m,
        Err(why) => return addons_page(&req, store, Some(Flash::Bad(format!("Not added. {why}")))).await,
    };
    let report = addons::check(&url, &manifest).await;
    let name = addons::manifest_facts(&manifest).map(|m| m.name).unwrap_or_else(|| "Add-on".into());
    let enabled = report.verdict != addons::Level::Bad;
    let report_json = serde_json::to_string(&report).unwrap_or_default();
    store.add_addon(&url, &name, &manifest.to_string(), &report_json, enabled).await?;
    let flash = if enabled {
        Flash::Ok(format!("Added {name}. {}", report.summary))
    } else {
        Flash::Bad(format!("Added {name}, but it's off: {} See the check below.", report.summary))
    };
    addons_page(&req, store, Some(flash)).await
}

pub async fn addon_action(req: Request, store: &Store, id: &str, action: &str) -> Result<Response> {
    let Some(addon) = store.addon(id).await? else {
        return web::redirect_with("/addons", false, "That add-on is gone.");
    };
    match action {
        "enable" | "disable" => {
            store.set_addon_enabled(id, action == "enable").await?;
            let state = if action == "enable" { "on" } else { "off" };
            web::redirect_with(
                "/addons",
                true,
                &format!("{} is {state}. Apps pick this up when they next start.", addon.name),
            )
        }
        "up" | "down" => {
            store.move_addon(id, action == "up").await?;
            web::redirect("/addons")
        }
        "delete" => {
            store.delete_addon(id).await?;
            web::redirect_with("/addons", true, &format!("Removed {}.", addon.name))
        }
        "check" => {
            let (manifest, report) = match addons::fetch_manifest(&addon.manifest_url).await {
                Ok(m) => {
                    let report = addons::check(&addon.manifest_url, &m).await;
                    (m.to_string(), report)
                }
                // Keep the last manifest read; the report says why this one failed.
                Err(why) => (addon.manifest.clone(), addons::unreadable(&why)),
            };
            let name = serde_json::from_str::<Value>(&manifest)
                .ok()
                .and_then(|m| addons::manifest_facts(&m))
                .map(|m| m.name)
                .unwrap_or(addon.name.clone());
            store.save_addon_check(id, &name, &manifest, &serde_json::to_string(&report).unwrap_or_default()).await?;
            let ok = report.verdict != addons::Level::Bad;
            addons_page(&req, store, Some(if ok { Flash::Ok(report.summary) } else { Flash::Bad(report.summary) }))
                .await
        }
        _ => web::redirect("/addons"),
    }
}
