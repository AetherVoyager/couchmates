//! App updates from GitHub Releases. The repo is private, so the Hub reads
//! releases with a read-only token from Settings and hands signed-in apps a
//! short-lived download link.

use serde_json::Value;
use worker::{Fetch, Headers, Method, Request, RequestInit, RequestRedirect, Result};

use crate::store::Store;

/// The installer each platform downloads from a release.
pub fn asset_name(platform: &str) -> Option<&'static str> {
    match platform {
        "windows" => Some("couchmates-windows-setup.exe"),
        _ => None,
    }
}

/// `v1.2.3` or `1.2.3` as numbers; anything after `-` or `+` is ignored.
pub fn parse_version(text: &str) -> Option<(u64, u64, u64)> {
    let core = text.trim().trim_start_matches('v').split(['-', '+']).next()?;
    let mut parts = core.split('.').map(|p| p.parse::<u64>().ok());
    let major = parts.next()??;
    let minor = parts.next().unwrap_or(Some(0))?;
    let patch = parts.next().unwrap_or(Some(0))?;
    Some((major, minor, patch))
}

pub fn is_newer(latest: &str, current: &str) -> bool {
    match (parse_version(latest), parse_version(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

/// `owner/name`, or None.
pub fn normalize_repo(input: &str) -> Option<String> {
    let t = input.trim().trim_end_matches('/').trim_end_matches(".git");
    let t = t.strip_prefix("https://github.com/").unwrap_or(t);
    let mut parts = t.split('/');
    let (owner, name) = (parts.next()?, parts.next()?);
    let ok = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    (parts.next().is_none() && ok(owner) && ok(name)).then(|| format!("{owner}/{name}"))
}

pub struct GitHubConfig {
    pub repo: String,
    pub token: String,
}

/// A release's installer for one platform.
pub struct Release {
    pub version: String,
    pub notes: Option<String>,
    pub asset_api_url: String,
    pub size_bytes: Option<u64>,
    pub file_name: String,
}

impl GitHubConfig {
    pub async fn load(store: &Store) -> Result<Option<Self>> {
        Ok(match (store.setting("github_repo").await?, store.setting("github_token").await?) {
            (Some(repo), Some(token)) => Some(Self { repo, token }),
            _ => None,
        })
    }

    fn headers(&self, accept: &str) -> Result<Headers> {
        let h = Headers::new();
        h.set("accept", accept)?;
        h.set("authorization", &format!("Bearer {}", self.token))?;
        h.set("x-github-api-version", "2022-11-28")?;
        // GitHub refuses requests without a User-Agent.
        h.set("user-agent", "couchmates-hub")?;
        Ok(h)
    }

    async fn get(&self, url: &str, accept: &str) -> std::result::Result<(u16, worker::Response), String> {
        let mut init = RequestInit::new();
        init.with_method(Method::Get)
            .with_headers(self.headers(accept).map_err(|e| e.to_string())?)
            .with_redirect(RequestRedirect::Manual);
        let req = Request::new_with_init(url, &init).map_err(|e| e.to_string())?;
        let resp = Fetch::Request(req).send().await.map_err(|e| format!("couldn't reach GitHub: {e}"))?;
        Ok((resp.status_code(), resp))
    }

    /// The newest versioned (not pre-release, not draft) release with an
    /// installer for [platform], or None.
    pub async fn latest(&self, platform: &str) -> std::result::Result<Option<Release>, String> {
        let Some(asset) = asset_name(platform) else {
            return Ok(None);
        };
        let url = format!("https://api.github.com/repos/{}/releases/latest", self.repo);
        let (status, mut resp) = self.get(&url, "application/vnd.github+json").await?;
        match status {
            200 => {}
            404 => return Ok(None),
            401 | 403 => {
                return Err("GitHub refused the token. Check it can read this repo's contents.".into());
            }
            s => return Err(format!("GitHub answered {s}")),
        }
        let release: Value = resp.json().await.map_err(|e| e.to_string())?;
        Ok(release_from_json(&release, asset))
    }

    /// A short-lived, header-free link to download [release]'s installer.
    pub async fn signed_download_url(&self, release: &Release) -> std::result::Result<String, String> {
        let (status, resp) = self.get(&release.asset_api_url, "application/octet-stream").await?;
        if (300..400).contains(&status) {
            if let Ok(Some(location)) = resp.headers().get("location") {
                return Ok(location);
            }
        }
        Err(format!("GitHub didn't hand out a download link ({status})"))
    }
}

pub fn release_from_json(release: &Value, asset: &str) -> Option<Release> {
    if release.get("draft").and_then(Value::as_bool) == Some(true)
        || release.get("prerelease").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let version = release.get("tag_name")?.as_str()?.trim_start_matches('v').to_string();
    parse_version(&version)?;
    let found =
        release.get("assets")?.as_array()?.iter().find(|a| a.get("name").and_then(Value::as_str) == Some(asset))?;
    Some(Release {
        version,
        notes: release.get("body").and_then(Value::as_str).filter(|b| !b.trim().is_empty()).map(str::to_string),
        asset_api_url: found.get("url")?.as_str()?.to_string(),
        size_bytes: found.get("size").and_then(Value::as_u64),
        file_name: asset.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn versions() {
        assert_eq!(parse_version("v0.1.0"), Some((0, 1, 0)));
        assert_eq!(parse_version("1.2"), Some((1, 2, 0)));
        assert_eq!(parse_version("2.0.1+5"), Some((2, 0, 1)));
        assert_eq!(parse_version("latest"), None);
        assert!(is_newer("0.2.0", "0.1.9"));
        assert!(is_newer("v1.0.0", "0.9.0"));
        assert!(!is_newer("0.1.0", "0.1.0"));
        assert!(!is_newer("0.1.0", "0.2.0"));
    }

    #[test]
    fn repos() {
        assert_eq!(
            normalize_repo("https://github.com/AetherVoyager/couchmates").as_deref(),
            Some("AetherVoyager/couchmates")
        );
        assert_eq!(normalize_repo("AetherVoyager/couchmates.git").as_deref(), Some("AetherVoyager/couchmates"));
        assert_eq!(normalize_repo("nope"), None);
        assert_eq!(normalize_repo("a/b/c"), None);
    }

    #[test]
    fn picks_the_installer_from_a_versioned_release() {
        let r = json!({
            "tag_name": "v0.2.0", "prerelease": false, "draft": false, "body": "Notes",
            "assets": [
                {"name": "couchmates-windows-x64-portable.7z", "url": "https://api/x/1", "size": 1},
                {"name": "couchmates-windows-setup.exe", "url": "https://api/x/2", "size": 2},
            ]
        });
        let release = release_from_json(&r, "couchmates-windows-setup.exe").unwrap();
        assert_eq!(release.version, "0.2.0");
        assert_eq!(release.asset_api_url, "https://api/x/2");
        let mut pre = r.clone();
        pre["prerelease"] = json!(true);
        assert!(release_from_json(&pre, "couchmates-windows-setup.exe").is_none());
    }
}
