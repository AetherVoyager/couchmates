//! The Hub's Cloudflare Worker: routes each request to the app API (Hub Core)
//! or an admin page handler, and runs the hourly job.

mod admin;
mod chat_live;

pub use chat_live::ChatLive;

use couchmates_hub_core::{api, bot, chat, crypto, jellyfin, requests, social, store, tgs, voice, web};

use worker::{Context, Env, Method, Request, Response, Result, ScheduleContext, ScheduledEvent, event};

#[event(fetch)]
pub async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    match route(req, &env).await {
        Ok(response) => Ok(response),
        Err(e) => {
            worker::console_error!("request failed: {e}");
            Response::error("Something went wrong on the Hub. Check the Worker logs.", 500)
        }
    }
}

async fn route(req: Request, env: &Env) -> Result<Response> {
    let path = req.path();
    let method = req.method();
    let store = store::Store::from_env(env)?;

    if path == "/api/health" {
        return web::json(&serde_json::json!({ "ok": true }), 200);
    }

    // App API: bearer tokens, no cookies.
    if let Some(rest) = path.strip_prefix("/api/app/") {
        return match (method, rest) {
            (Method::Post, "login") => api::login(req, &store).await,
            (Method::Post, "password") => api::change_password(req, &store).await,
            (Method::Get, "config") => api::config(req, &store).await,
            (Method::Post, "voice-token") => api::voice_token(req, &store).await,
            (Method::Post, "voice/peers") => voice::peers(req, &store, env).await,
            (Method::Post, "voice/signal") => voice::send_signal(req, &store, env).await,
            (Method::Post, "logout") => api::logout(req, &store).await,
            (Method::Get, "update") => api::update(req, &store).await,
            (Method::Post, "update/download") => api::update_download(req, &store).await,
            (Method::Get, "trackers") => api::trackers(req, &store).await,
            (Method::Post, "trackers/link") => api::tracker_link(req, &store).await,
            (Method::Post, "trackers/poll") => api::tracker_poll(req, &store).await,
            (Method::Post, "trackers/unlink") => api::tracker_unlink(req, &store).await,
            (Method::Post, "scrobble") => api::scrobble(req, &store).await,
            (Method::Get, "credits") => api::credits(req, &store).await,
            (Method::Get, "profile") => api::profile(req, &store).await,
            (Method::Post, "profile") => api::update_profile(req, &store).await,
            (Method::Post, "devices/sign-out") => api::sign_out_device(req, &store).await,
            (Method::Post, "profile/photo") => api::upload_photo(req, &store).await,
            (Method::Post, "profile/photo/remove") => api::remove_photo(req, &store).await,
            (Method::Get, p) if p.starts_with("photos/") => {
                let user_id = p["photos/".len()..].to_string();
                api::photo(req, &store, &user_id).await
            }
            (Method::Post, "presence") => social::presence(req, &store).await,
            (Method::Post, "join-requests") => social::create_join_request(req, &store).await,
            (Method::Post, "join-requests/answer") => social::answer_join_request(req, &store).await,
            (Method::Post, "join-requests/cancel") => social::cancel_join_request(req, &store).await,
            (Method::Get, "tracks") => api::file_tracks(req, &store).await,
            (Method::Post, "tracks") => api::save_file_tracks(req, &store).await,
            (Method::Get, "chat") => chat::channels(req, &store).await,
            (Method::Get, "chat/messages") => chat::messages(req, &store).await,
            (Method::Post, "chat/send") => chat::send(req, &store, env).await,
            (Method::Post, "chat/read") => chat::read(req, &store).await,
            (Method::Post, "chat/delete") => chat::delete(req, &store, env).await,
            (Method::Post, "chat/mute") => chat::mute(req, &store, env).await,
            (Method::Get, "chat/live") => chat::live(req, &store, env).await,
            (Method::Get, "requests") => requests::list(req, &store).await,
            (Method::Post, "requests") => requests::create(req, &store).await,
            (Method::Post, "requests/cancel") => requests::cancel(req, &store).await,
            (Method::Post, "requests/episodes") => requests::create_episodes(req, &store).await,
            _ => web::json_error("Not found", 404),
        };
    }

    // Bot API: the admin's own program, with the bot token.
    if let Some(rest) = path.strip_prefix("/api/bot/") {
        return match (method, rest) {
            (Method::Get, "requests") => bot::list(req, &store).await,
            (Method::Post, "requests/update") => bot::update(req, &store).await,
            (Method::Post, "status") => bot::status(req, &store).await,
            _ => web::json_error("Not found", 404),
        };
    }

    // A Jellyfin look-alike for the admin's Tracearr, with its own API key.
    if path.eq_ignore_ascii_case(jellyfin::PREFIX) || path.to_ascii_lowercase().starts_with("/jellyfin/") {
        let rest = path[jellyfin::PREFIX.len()..].to_string();
        return jellyfin::handle(req, &store, &rest).await;
    }

    if method == Method::Post && !web::same_origin(&req) {
        return Response::error("Cross-site form posts aren't allowed.", 403);
    }

    match (method.clone(), path.as_str()) {
        (Method::Get, "/login") => return admin::login_page(),
        (Method::Post, "/login") => return admin::login(req, env, &store).await,
        (Method::Post, "/logout") => return admin::logout(&req, &store).await,
        _ => {}
    }

    match admin::session(&req, &store).await? {
        admin::AdminSession::None => return web::redirect("/login"),
        admin::AdminSession::NeedsTwoFactorSetup => {
            return match (method, path.as_str()) {
                (Method::Get, "/setup-2fa") => admin::setup_2fa_page(&store, None).await,
                (Method::Post, "/setup-2fa") => admin::setup_2fa(req, &store).await,
                _ => web::redirect("/setup-2fa"),
            };
        }
        admin::AdminSession::Full => {}
    }

    let segments: Vec<&str> = path.trim_matches('/').split('/').collect();
    match (method, segments.as_slice()) {
        (Method::Get, [""]) => admin::overview(&req, &store).await,
        (Method::Get, ["users"]) => admin::users_page(&req, &store).await,
        (Method::Post, ["users"]) => admin::create_user(req, &store).await,
        (Method::Get, ["users", id]) => {
            let id = id.to_string();
            admin::user_page(&req, &store, &id).await
        }
        (Method::Post, ["users", id, "devices", device, "delete"]) => {
            let (id, device) = (id.to_string(), device.to_string());
            admin::user_action(req, &store, env, &id, "device-delete", Some(&device)).await
        }
        (Method::Post, ["users", id, action]) => {
            let (id, action) = (id.to_string(), action.to_string());
            admin::user_action(req, &store, env, &id, &action, None).await
        }
        (Method::Get, ["addons"]) => admin::addons_page(&req, &store, None).await,
        (Method::Post, ["addons"]) => admin::add_addon(req, &store).await,
        (Method::Post, ["addons", id, action]) => {
            let (id, action) = (id.to_string(), action.to_string());
            admin::addon_action(req, &store, &id, &action).await
        }
        (Method::Get, ["requests"]) => admin::requests_page(&req, &store, None).await,
        (Method::Post, ["requests", "check"]) => admin::check_requests(&store).await,
        (Method::Post, ["requests", "clear"]) => admin::clear_answered_requests(&store).await,
        (Method::Post, ["requests", id, action]) => {
            let (id, action) = (id.to_string(), action.to_string());
            admin::request_action(req, &store, &id, &action).await
        }
        (Method::Post, ["bot", action]) => {
            let action = action.to_string();
            admin::bot_action(req, &store, &action).await
        }
        (Method::Get, ["settings"]) => admin::settings_page(&req, &store, None).await,
        (Method::Post, ["settings", "tgs"]) => admin::save_tgs(req, &store).await,
        (Method::Post, ["settings", "tgs", "show-catalog"]) => admin::show_catalog(req, &store).await,
        (Method::Post, ["settings", "livekit"]) => admin::save_livekit(req, &store).await,
        (Method::Post, ["settings", "voice"]) => admin::save_voice(req, &store).await,
        (Method::Post, ["settings", "updates"]) => admin::save_updates(req, &store).await,
        (Method::Post, ["settings", "trackers"]) => admin::save_trackers(req, &store).await,
        (Method::Post, ["settings", "tmdb"]) => admin::save_tmdb(req, &store).await,
        (Method::Post, ["settings", "chat"]) => admin::save_chat(req, &store).await,
        (Method::Post, ["settings", "tracearr", action]) => {
            let action = action.to_string();
            admin::tracearr_action(&req, &store, &action).await
        }
        (Method::Post, ["settings", "2fa", "reset"]) => admin::reset_2fa(req, &store).await,
        (Method::Get, ["setup-2fa"]) => web::redirect("/"),
        _ => Response::error("Not found", 404),
    }
}

/// Hourly: copies each user's running data total for the usage chart, and
/// clears out expired rows.
#[event(scheduled)]
pub async fn scheduled(_event: ScheduledEvent, env: Env, _ctx: ScheduleContext) {
    if let Err(e) = snapshot(&env).await {
        worker::console_error!("hourly snapshot failed: {e}");
    }
}

async fn snapshot(env: &Env) -> Result<()> {
    let store = store::Store::from_env(env)?;
    store.cleanup().await?;
    match requests::sync_with_library(&store).await {
        Ok(added) if !added.is_empty() => worker::console_log!("requests now in the library: {}", added.len()),
        Ok(_) => {}
        Err(e) => worker::console_warn!("request check failed: {e}"),
    }
    let Ok(mut client) = tgs::TgsClient::new(&store).await else {
        return Ok(());
    };
    let stats = match client.system_stats().await {
        Ok(s) => s,
        Err(e) => {
            worker::console_warn!("snapshot skipped: {e}");
            return Ok(());
        }
    };
    let by_hash: std::collections::HashMap<String, f64> =
        tgs::token_usages(&stats).into_iter().map(|u| (crypto::sha256_hex(&u.token), u.total_bytes)).collect();
    let points: Vec<(String, f64)> = store
        .users()
        .await?
        .into_iter()
        .filter_map(|u| Some((u.id.clone(), *by_hash.get(u.tgs_token_hash.as_ref()?)?)))
        .collect();
    let now = store::now();
    store.record_usage(&points, now - now.rem_euclid(3600)).await
}
