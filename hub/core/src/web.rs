//! Request and response helpers.

use serde::Serialize;
use worker::{Headers, Request, Response, Result};

/// A message shown at the top of the next page.
pub enum Flash {
    Ok(String),
    Bad(String),
}

pub const SESSION_COOKIE: &str = "hub_session";
pub const SESSION_TTL_SECS: i64 = 7 * 86_400;

pub fn cookie(req: &Request, name: &str) -> Option<String> {
    let header = req.headers().get("cookie").ok()??;
    header.split(';').map(str::trim).find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == name && !v.is_empty()).then(|| v.to_string())
    })
}

pub fn bearer(req: &Request) -> Option<String> {
    let header = req.headers().get("authorization").ok()??;
    header.strip_prefix("Bearer ").map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

pub fn client_ip(req: &Request) -> String {
    req.headers().get("cf-connecting-ip").ok().flatten().unwrap_or_else(|| "unknown".into())
}

/// A form post from this site, or from a non-browser client (which sends no
/// fetch metadata). Blocks cross-site form posts on top of the SameSite cookie.
pub fn same_origin(req: &Request) -> bool {
    // Browsers send Sec-Fetch-Site on every request; trust it first.
    if let Some(site) = req.headers().get("sec-fetch-site").ok().flatten() {
        return matches!(site.as_str(), "same-origin" | "none");
    }
    let Ok(url) = req.url() else { return false };
    match req.headers().get("origin").ok().flatten() {
        Some(o) => o == url.origin().ascii_serialization(),
        None => true,
    }
}

fn security_headers(headers: &Headers) -> Result<()> {
    headers.set(
        "content-security-policy",
        "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    )?;
    headers.set("x-content-type-options", "nosniff")?;
    headers.set("referrer-policy", "same-origin")?;
    headers.set("cache-control", "no-store")?;
    Ok(())
}

pub fn html(page: String) -> Result<Response> {
    html_status(page, 200)
}

pub fn html_status(page: String, status: u16) -> Result<Response> {
    let response = Response::from_html(page)?.with_status(status);
    security_headers(response.headers())?;
    Ok(response)
}

/// A 303 to [path] on this site, optionally with a message for the next page.
pub fn redirect(path: &str) -> Result<Response> {
    let headers = Headers::new();
    headers.set("location", path)?;
    headers.set("cache-control", "no-store")?;
    Ok(Response::empty()?.with_status(303).with_headers(headers))
}

pub fn redirect_with(path: &str, ok: bool, message: &str) -> Result<Response> {
    redirect(&redirect_target(path, ok, message))
}

/// [path] (which may carry a query, such as `/requests?status=open`) with the flash message added to its query.
pub fn redirect_target(path: &str, ok: bool, message: &str) -> String {
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    let mut url = worker::Url::parse("http://x").expect("static url");
    url.set_path(path);
    url.set_query((!query.is_empty()).then_some(query));
    url.query_pairs_mut().append_pair(if ok { "ok" } else { "err" }, message);
    format!("{}?{}", url.path(), url.query().unwrap_or_default())
}

pub fn json<T: Serialize>(value: &T, status: u16) -> Result<Response> {
    let response = Response::from_json(value)?.with_status(status);
    response.headers().set("cache-control", "no-store")?;
    Ok(response)
}

pub fn json_error(message: &str, status: u16) -> Result<Response> {
    json(&serde_json::json!({ "error": message }), status)
}

pub fn session_cookie_header(token: &str) -> String {
    format!("{SESSION_COOKIE}={token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age={SESSION_TTL_SECS}")
}

pub fn clear_session_cookie_header() -> String {
    format!("{SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0")
}

/// The `?ok=` / `?err=` message a redirect carried.
pub fn flash_from_query(req: &Request) -> Option<Flash> {
    let url = req.url().ok()?;
    for (k, v) in url.query_pairs() {
        match k.as_ref() {
            "ok" => return Some(Flash::Ok(v.into_owned())),
            "err" => return Some(Flash::Bad(v.into_owned())),
            _ => {}
        }
    }
    None
}

/// A form number, treating blank or invalid as 0 and clamping negatives.
pub fn parse_gb(value: Option<String>) -> f64 {
    value.and_then(|v| v.trim().parse::<f64>().ok()).filter(|v| v.is_finite()).map_or(0.0, |v| v.max(0.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flash_redirects_keep_the_path_and_its_query() {
        assert_eq!(redirect_target("/users", true, "Saved."), "/users?ok=Saved.");
        assert_eq!(
            redirect_target("/requests?status=open", true, "Avengers: Endgame is pending."),
            "/requests?status=open&ok=Avengers%3A+Endgame+is+pending."
        );
    }
}
