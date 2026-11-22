//! "Check catalog" on a user's page: reads the user's Stremio addon with
//! their own token, the way the app does, and says why the app would show
//! nothing.
//!
//! Telegram-Stremio (`stremio_routes.py`) hides titles from ordinary tokens
//! when their `visibility` isn't public, and lists no catalogs at all when
//! its global "Hide catalog" setting is on. The owner's own token sees
//! everything, so Stremio can look fine to the admin while users see nothing.

use serde_json::Value;

use crate::tgs::{TgsClient, TgsResult};

/// Telegram-Stremio pages in 15s; one page per catalog is enough to tell.
const MAX_CATALOGS: usize = 12;

#[derive(Debug, Clone, PartialEq)]
pub enum Rows {
    Titles(usize),
    Failed(u16, String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct CatalogRow {
    pub label: String,
    pub rows: Rows,
}

/// What the check found, and what it means.
#[derive(Debug, Clone, PartialEq)]
pub struct CatalogCheck {
    /// Catalogs the manifest lists, or why the manifest couldn't be read.
    pub manifest: Result<usize, (u16, String)>,
    pub catalogs: Vec<CatalogRow>,
    /// Movies plus shows in the whole library, from the admin stats.
    pub library_titles: Option<u64>,
    /// Telegram-Stremio's "Hide Catalog" setting, when it could be read.
    pub hide_catalog: Option<bool>,
    pub ok: bool,
    pub verdict: String,
}

fn detail(body: &str) -> String {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("detail").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_default()
}

/// The verdict for what was found. Pure, so it's tested without servers.
pub fn judge(
    manifest: &Result<usize, (u16, String)>,
    catalogs: &[CatalogRow],
    library_titles: Option<u64>,
) -> (bool, String) {
    match manifest {
        Err((401, _)) => {
            return (false, "Telegram-Stremio doesn't accept this user's token. Disable and enable the user to give them a new one.".into());
        }
        Err((404, _)) => {
            return (false, "There's no Stremio addon at the server address in Settings. Use the address you install the Telegram-Stremio addon from (without /stremio/...).".into());
        }
        Err((0, why)) => return (false, format!("Couldn't reach Telegram-Stremio: {why}")),
        Err((status, why)) => {
            return (false, format!("Telegram-Stremio answered {status} for the manifest. {why}"));
        }
        Ok(0) => {
            return (false, "Telegram-Stremio lists no catalogs for this user, so the app has no rows. Its \"Hide catalog\" setting is probably on: turn it off in Telegram-Stremio's settings.".into());
        }
        Ok(_) => {}
    }
    if catalogs.iter().any(|c| matches!(&c.rows, Rows::Failed(404, d) if d.contains("disabled"))) {
        return (false, "Telegram-Stremio's \"Hide catalog\" setting is on, so catalogs are disabled. Turn it off in Telegram-Stremio's settings.".into());
    }
    let titles: usize = catalogs.iter().map(|c| if let Rows::Titles(n) = c.rows { n } else { 0 }).sum();
    if titles > 0 {
        let rows = catalogs.iter().filter(|c| matches!(c.rows, Rows::Titles(n) if n > 0)).count();
        return (
            true,
            format!("All good: the app will show {rows} row{} for this user.", if rows == 1 { "" } else { "s" }),
        );
    }
    if catalogs.iter().all(|c| matches!(c.rows, Rows::Failed(..))) {
        return (false, "Every catalog failed to load for this user; see the list below.".into());
    }
    match library_titles {
        Some(0) => (false, "The Telegram-Stremio library is empty. Titles added there show up here.".into()),
        Some(n) => (
            false,
            format!(
                "The library has {n} titles, but this user can see none of them. Telegram-Stremio hides titles from ordinary \
                 tokens unless their visibility is public (or allows this user's token), and titles locked to a custom \
                 catalog. Make the titles public in Telegram-Stremio, or allow this user's token on them."
            ),
        ),
        None => (false, "Every catalog is empty for this user. If the library has titles, check their visibility in Telegram-Stremio: only public ones show for users.".into()),
    }
}

/// Reads the manifest and the first page of each catalog with [token].
pub async fn check(client: &mut TgsClient<'_>, token: &str) -> TgsResult<CatalogCheck> {
    let base = format!("/stremio/{token}");
    let hide_catalog = client.hide_catalog().await.ok();
    let library_titles = client.system_stats().await.ok().map(|s| {
        let n = |k: &str| s.get(k).and_then(Value::as_f64).unwrap_or(0.0) as u64;
        n("movies") + n("tv_shows")
    });
    let (status, body) = match client.addon_get(&format!("{base}/manifest.json")).await {
        Ok(r) => r,
        Err(e) => (0, e.to_string()),
    };
    let mut catalogs = Vec::new();
    let manifest = if (200..300).contains(&status) {
        let list: Vec<Value> = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|m| m.get("catalogs").and_then(Value::as_array).cloned())
            .unwrap_or_default();
        for c in list.iter().take(MAX_CATALOGS) {
            let (Some(kind), Some(id)) = (c.get("type").and_then(Value::as_str), c.get("id").and_then(Value::as_str))
            else {
                continue;
            };
            let name = c.get("name").and_then(Value::as_str).unwrap_or(id);
            let label = format!(
                "{} · {name}",
                if kind == "series" {
                    "Shows"
                } else if kind == "movie" {
                    "Movies"
                } else {
                    kind
                }
            );
            // Search-only catalogs can't be shown as a row; skip them like the app does.
            let needs_input = c
                .get("extra")
                .and_then(Value::as_array)
                .is_some_and(|e| e.iter().any(|x| x.get("isRequired").and_then(Value::as_bool) == Some(true)));
            if needs_input {
                continue;
            }
            let rows = match client.addon_get(&format!("{base}/catalog/{kind}/{id}.json")).await {
                Ok((s, b)) if (200..300).contains(&s) => Rows::Titles(
                    serde_json::from_str::<Value>(&b)
                        .ok()
                        .and_then(|v| v.get("metas").and_then(Value::as_array).map(Vec::len))
                        .unwrap_or(0),
                ),
                Ok((s, b)) => Rows::Failed(s, detail(&b)),
                Err(e) => Rows::Failed(0, e.to_string()),
            };
            catalogs.push(CatalogRow { label, rows });
        }
        Ok(list.len())
    } else {
        Err((status, if status == 0 { body } else { detail(&body) }))
    };
    let (ok, mut verdict) = judge(&manifest, &catalogs, library_titles);
    if hide_catalog == Some(true) && !ok {
        verdict = "Telegram-Stremio's \"Hide Catalog\" setting is on. Despite its description, it hides catalogs from every \
                   token, including your users', so the app has no rows. Turn it off with the button below, or untick it \
                   in Telegram-Stremio's panel (Settings → General)."
            .into();
    }
    Ok(CatalogCheck { manifest, catalogs, library_titles, hide_catalog, ok, verdict })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(n: usize) -> CatalogRow {
        CatalogRow { label: "Movies · Recently Added".into(), rows: Rows::Titles(n) }
    }

    #[test]
    fn verdicts() {
        assert!(judge(&Ok(2), &[row(3), row(0)], Some(10)).0);
        let (ok, why) = judge(&Ok(2), &[row(0), row(0)], Some(128));
        assert!(!ok && why.contains("128 titles") && why.contains("visibility"));
        assert!(judge(&Ok(2), &[row(0)], Some(0)).1.contains("library is empty"));
        assert!(judge(&Ok(0), &[], Some(5)).1.contains("Hide catalog"));
        let disabled = CatalogRow { label: "x".into(), rows: Rows::Failed(404, "Catalog disabled".into()) };
        assert!(judge(&Ok(2), &[disabled], Some(5)).1.contains("Hide catalog"));
        assert!(judge(&Err((401, String::new())), &[], None).1.contains("token"));
        assert!(judge(&Err((404, String::new())), &[], None).1.contains("server address"));
    }
}
