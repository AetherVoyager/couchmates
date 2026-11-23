//! Title requests: friends search the app for a movie or show that isn't in the library and ask for it. The
//! admin answers on the dashboard's Requests page and adds the title to Telegram-Stremio by hand; the Hub
//! never downloads anything.

pub use couchmates_core::api::request_status;
use couchmates_core::api::{MediaRequest, MediaRequestCancel, MediaRequestCreate, MediaRequests, OkResponse};
use worker::{Request, Response, Result};

use crate::api::authenticate;
use crate::store::{MediaRequestRow, Store};
use crate::web::{self, json_error};

/// Requests one user can be waiting on at once (pending or approved).
pub const MAX_OPEN_PER_USER: i64 = 50;
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
    Ok(MediaRequestCreate { kind: body.kind, title_id, name, year, poster })
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

/// `POST /api/app/requests`: asks for a title, or joins the request there is.
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
    if store.open_requests_of(&user.id).await? >= MAX_OPEN_PER_USER {
        return json_error("You have 50 requests waiting. Wait for the admin to get through some first.", 429);
    }
    let row = store
        .ask_for_title(&user.id, &body.kind, &body.title_id, &body.name, body.year.as_deref(), body.poster.as_deref())
        .await?;
    match row {
        Some(row) => web::json(&to_api(row), 200),
        None => json_error("The request wasn't saved. Try again.", 500),
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
        }
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
}
