//! Public Stremio add-ons the admin adds in the dashboard (Add-ons page). The
//! app calls them directly, next to Telegram-Stremio: their catalogs become
//! home rows, and their details, streams and subtitles are merged in.
//!
//! Adding one runs a compatibility check: it reads the manifest, then tries
//! one page of a few catalogs, a details page, streams and subtitles for a
//! sample title, and judges each answer the way the app would use it.

use std::time::Duration;

use futures_util::future::{Either, join_all, select};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use worker::{Delay, Fetch, Headers, Method, Request, RequestInit};

/// Resources the app reads. Others (`addon_catalog`, …) are ignored.
pub const APP_RESOURCES: &[&str] = &["catalog", "meta", "stream", "subtitles"];

/// Types the app's screens are made for. Others show as rows, but details
/// and episodes may not look right.
pub const APP_TYPES: &[&str] = &["movie", "series"];

/// Catalogs tried during a check; the rest are counted but not fetched.
const CATALOGS_TRIED: usize = 6;

/// A sample movie and episode with streams and subtitles everywhere, for
/// add-ons that look titles up by IMDb id.
const SAMPLE_MOVIE: &str = "tt0133093";
const SAMPLE_EPISODE: &str = "tt0903747:1:1";

const TIMEOUT: Duration = Duration::from_secs(20);

/// The manifest URL for what the admin pasted: an `https://…/manifest.json`
/// link, Stremio's `stremio://…` install link, or the add-on's base address.
pub fn normalize_manifest_url(input: &str) -> Option<String> {
    let input = input.trim();
    let url = match input.strip_prefix("stremio://") {
        Some(rest) => format!("https://{rest}"),
        None => input.to_string(),
    };
    let parsed = url::Url::parse(&url).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return None;
    }
    let trimmed = url.trim_end_matches('/');
    Some(if trimmed.ends_with("/manifest.json") { trimmed.to_string() } else { format!("{trimmed}/manifest.json") })
}

/// `<base>/catalog/…` and the other resources hang off this.
pub fn base_url(manifest_url: &str) -> &str {
    manifest_url.strip_suffix("/manifest.json").unwrap_or(manifest_url)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    /// A note that doesn't change the verdict.
    Info,
    Warn,
    Bad,
}

/// One line of the check.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Finding {
    pub level: Level,
    pub text: String,
}

impl Finding {
    fn ok(text: impl Into<String>) -> Self {
        Self { level: Level::Ok, text: text.into() }
    }
    fn info(text: impl Into<String>) -> Self {
        Self { level: Level::Info, text: text.into() }
    }
    fn warn(text: impl Into<String>) -> Self {
        Self { level: Level::Warn, text: text.into() }
    }
    fn bad(text: impl Into<String>) -> Self {
        Self { level: Level::Bad, text: text.into() }
    }
}

/// What the check found, saved with the add-on and shown on the page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    /// Ok: everything it offers works in the app. Warn: some of it does.
    /// Bad: nothing the app can use.
    pub verdict: Level,
    pub summary: String,
    /// What the add-on adds to the app, such as "6 home rows" or "subtitles".
    pub adds: Vec<String>,
    pub findings: Vec<Finding>,
}

/// The parts of a manifest the check and the page use.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ManifestFacts {
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    pub types: Vec<String>,
    /// Resource names, from strings or `{name, types, idPrefixes}` objects.
    pub resources: Vec<String>,
    pub id_prefixes: Option<Vec<String>>,
    pub catalogs: Vec<CatalogFacts>,
    pub needs_configuration: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CatalogFacts {
    pub kind: String,
    pub id: String,
    pub name: String,
    /// Needs an extra (such as `search`) on every request: no home row.
    pub needs_input: bool,
    pub searchable: bool,
}

fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

/// Reads a manifest leniently, like the app does. None if it isn't one.
pub fn manifest_facts(m: &Value) -> Option<ManifestFacts> {
    let obj = m.as_object()?;
    let id = obj.get("id")?.as_str()?.to_string();
    let name = obj.get("name").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or(&id).to_string();
    let resources = obj
        .get("resources")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|r| r.as_str().or_else(|| r.get("name").and_then(Value::as_str)))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let catalogs = obj
        .get("catalogs")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(catalog_facts).collect())
        .unwrap_or_default();
    let hints = obj.get("behaviorHints");
    Some(ManifestFacts {
        id,
        name,
        version: obj.get("version").and_then(Value::as_str).unwrap_or("").to_string(),
        description: obj.get("description").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string),
        types: strings(obj.get("types")),
        resources,
        id_prefixes: obj.get("idPrefixes").map(|v| strings(Some(v))).filter(|v| !v.is_empty()),
        catalogs,
        needs_configuration: hints.and_then(|h| h.get("configurationRequired")).and_then(Value::as_bool) == Some(true),
    })
}

fn catalog_facts(c: &Value) -> Option<CatalogFacts> {
    let kind = c.get("type")?.as_str()?.to_string();
    let id = c.get("id")?.as_str()?.to_string();
    let name = c.get("name").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or(&id).to_string();
    let (mut needs_input, mut searchable) = (false, false);
    if let Some(extra) = c.get("extra").and_then(Value::as_array) {
        for e in extra {
            let required = e.get("isRequired").and_then(Value::as_bool) == Some(true);
            needs_input |= required;
            searchable |= e.get("name").and_then(Value::as_str) == Some("search");
        }
    } else {
        let required = strings(c.get("extraRequired"));
        needs_input = !required.is_empty();
        searchable = strings(c.get("extraSupported")).iter().any(|n| n == "search");
    }
    Some(CatalogFacts { kind, id, name, needs_input, searchable })
}

fn type_label(kind: &str) -> &str {
    match kind {
        "movie" => "movies",
        "series" => "shows",
        other => other,
    }
}

/// How the app would use a stream list, counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StreamKinds {
    /// `http(s)` URLs: mpv plays these.
    pub playable: usize,
    /// `externalUrl`: the app offers these as links that open outside it.
    pub links: usize,
    /// `infoHash`: torrents. The app doesn't play them.
    pub torrents: usize,
    /// `ytId` and anything else.
    pub other: usize,
}

pub fn stream_kinds(body: &Value) -> StreamKinds {
    let mut k = StreamKinds::default();
    for s in body.get("streams").and_then(Value::as_array).into_iter().flatten() {
        let url = s.get("url").and_then(Value::as_str).unwrap_or("");
        if url.starts_with("http://") || url.starts_with("https://") {
            k.playable += 1;
        } else if s.get("externalUrl").and_then(Value::as_str).is_some_and(|u| u.starts_with("http")) {
            k.links += 1;
        } else if s.get("infoHash").is_some() {
            k.torrents += 1;
        } else {
            k.other += 1;
        }
    }
    k
}

/// The answer to one probe: the HTTP status and the JSON body, or why there
/// was none.
pub type Probe = Result<(u16, Value), String>;

fn probe_problem(what: &str, probe: &Probe) -> Option<String> {
    match probe {
        Err(why) => Some(format!("{what}: {why}")),
        Ok((status, _)) if !(200..300).contains(status) => Some(format!("{what}: the add-on answered {status}")),
        Ok(_) => None,
    }
}

pub fn takes_imdb(m: &ManifestFacts) -> bool {
    m.id_prefixes.as_ref().is_none_or(|p| p.iter().any(|p| p.starts_with("tt")))
}

/// Everything fetched for a check, so judging it is pure.
#[derive(Debug, Clone, Default)]
pub struct Probes {
    /// `(catalog index, answer)` for the catalogs tried.
    pub catalogs: Vec<(usize, Probe)>,
    /// `(type, id, answer)`.
    pub metas: Vec<(String, String, Probe)>,
    pub streams: Vec<(String, String, Probe)>,
    pub subtitles: Vec<(String, String, Probe)>,
}

fn items(body: &Value, key: &str) -> usize {
    body.get(key).and_then(Value::as_array).map_or(0, Vec::len)
}

/// Judges an add-on from its manifest and what the probes got back.
pub fn judge(m: &ManifestFacts, probes: &Probes) -> Report {
    let mut findings = Vec::new();
    let mut adds = Vec::new();
    // Each resource the add-on offers and the app reads: did it work?
    let mut offered = 0;
    let mut working = 0;

    if m.needs_configuration {
        findings.push(Finding::bad(
            "It needs setting up first. Open its configure page, then paste the manifest link it gives you.",
        ));
        return Report {
            verdict: Level::Bad,
            summary: "Needs configuring before it can be used.".into(),
            adds,
            findings,
        };
    }

    let used: Vec<&str> = m.resources.iter().map(String::as_str).filter(|r| APP_RESOURCES.contains(r)).collect();
    let unused: Vec<&str> = m.resources.iter().map(String::as_str).filter(|r| !APP_RESOURCES.contains(r)).collect();
    if used.is_empty() {
        findings.push(Finding::bad(format!(
            "It offers {}, none of which the app uses (catalogs, details, streams, subtitles).",
            if unused.is_empty() { "nothing".to_string() } else { unused.join(", ") }
        )));
        return Report { verdict: Level::Bad, summary: "Nothing the app can use.".into(), adds, findings };
    }
    if !unused.is_empty() {
        findings.push(Finding::info(format!("Not used by the app: {}.", unused.join(", "))));
    }
    let odd_types: Vec<&str> = m.types.iter().map(String::as_str).filter(|t| !APP_TYPES.contains(t)).collect();
    if !odd_types.is_empty() {
        findings.push(Finding::warn(format!(
            "Types the app isn't made for: {}. They show as rows, but their pages may look incomplete.",
            odd_types.join(", ")
        )));
    }
    if !takes_imdb(m) {
        findings.push(Finding::warn(format!(
            "It uses its own ids ({}), so it won't match titles in your library, trackers or watch parties.",
            m.id_prefixes.as_deref().unwrap_or_default().join(", ")
        )));
    }

    // Catalogs: home rows and search.
    if m.resources.iter().any(|r| r == "catalog") {
        offered += 1;
        let rows: Vec<&CatalogFacts> = m.catalogs.iter().filter(|c| !c.needs_input).collect();
        let search = m.catalogs.iter().filter(|c| c.searchable).count();
        let mut filled = 0;
        let mut empty = Vec::new();
        let mut failed = Vec::new();
        for (i, probe) in &probes.catalogs {
            let Some(c) = m.catalogs.get(*i) else { continue };
            let label = format!("{} ({})", c.name, type_label(&c.kind));
            match probe_problem(&label, probe) {
                Some(p) => failed.push(p),
                None => {
                    let n = probe.as_ref().map(|(_, b)| items(b, "metas")).unwrap_or(0);
                    if n > 0 { filled += 1 } else { empty.push(label) }
                }
            }
        }
        let untried = rows.len().saturating_sub(probes.catalogs.len());
        if m.catalogs.is_empty() {
            findings.push(Finding::warn("It says it has catalogs but lists none."));
        } else if rows.is_empty() {
            findings.push(Finding::warn("Its catalogs all need a search or other input, so they add no home rows."));
        } else if filled == 0 {
            findings.push(Finding::bad(match failed.first() {
                Some(p) => format!("Its catalogs didn't load. {p}."),
                None => "Its catalogs came back empty.".to_string(),
            }));
        } else {
            working += 1;
            let mut text = format!("{filled} of the {} catalogs tried loaded", probes.catalogs.len());
            if untried > 0 {
                text.push_str(&format!(" ({untried} more not tried)"));
            }
            text.push('.');
            findings.push(Finding::ok(text));
            adds.push(format!("{} home row{}", rows.len(), if rows.len() == 1 { "" } else { "s" }));
        }
        for p in failed.iter().skip(usize::from(filled == 0)) {
            findings.push(Finding::warn(format!("{p}.")));
        }
        if !empty.is_empty() && filled > 0 {
            findings.push(Finding::warn(format!("Empty right now: {}.", empty.join(", "))));
        }
        if search > 0 {
            adds.push("search".into());
        }
    }

    // Details.
    if m.resources.iter().any(|r| r == "meta") {
        offered += 1;
        let good = probes
            .metas
            .iter()
            .any(|(_, _, p)| matches!(p, Ok((200..=299, b)) if b.get("meta").is_some_and(Value::is_object)));
        if probes.metas.is_empty() {
            findings.push(Finding::warn("Details weren't tried: no sample title to ask for."));
        } else if good {
            working += 1;
            findings.push(Finding::ok("Details pages load."));
            adds.push("details".into());
        } else {
            let why = probes.metas.iter().find_map(|(k, id, p)| probe_problem(&format!("{k} {id}"), p));
            findings.push(Finding::bad(match why {
                Some(w) => format!("Details didn't load. {w}."),
                None => "Details came back empty for the sample titles.".into(),
            }));
        }
    }

    // Streams.
    if m.resources.iter().any(|r| r == "stream") {
        offered += 1;
        let mut total = StreamKinds::default();
        let mut problems = Vec::new();
        for (kind, id, p) in &probes.streams {
            match (probe_problem(&format!("{kind} {id}"), p), p) {
                (Some(why), _) => problems.push(why),
                (None, Ok((_, body))) => {
                    let k = stream_kinds(body);
                    total.playable += k.playable;
                    total.links += k.links;
                    total.torrents += k.torrents;
                    total.other += k.other;
                }
                _ => {}
            }
        }
        if probes.streams.is_empty() {
            findings.push(Finding::warn("Streams weren't tried: no sample title to ask for."));
        } else if total.playable > 0 {
            working += 1;
            findings.push(Finding::ok(format!("{} playable stream(s) found for the sample titles.", total.playable)));
            adds.push("streams".into());
        } else if total.links > 0 {
            working += 1;
            findings.push(Finding::ok(format!(
                "{} link(s) to watch elsewhere (such as a streaming service). The app shows them as links that open outside it.",
                total.links
            )));
            adds.push("watch-elsewhere links".into());
        } else if problems.len() == probes.streams.len() {
            findings.push(Finding::bad(format!("Streams didn't load. {}.", problems[0])));
        } else if total.torrents == 0 && total.other == 0 {
            findings.push(Finding::warn("No streams for the sample titles, so this couldn't be confirmed."));
        }
        if total.torrents > 0 {
            findings.push(Finding::bad(format!(
                "{} torrent stream(s). The app doesn't play torrents, so these are left out.",
                total.torrents
            )));
        }
        if total.other > 0 {
            findings.push(Finding::warn(format!(
                "{} stream(s) of a kind the app can't play (such as YouTube ids).",
                total.other
            )));
        }
    }

    // Subtitles.
    if m.resources.iter().any(|r| r == "subtitles") {
        offered += 1;
        let found: usize =
            probes.subtitles.iter().filter_map(|(_, _, p)| p.as_ref().ok()).map(|(_, b)| items(b, "subtitles")).sum();
        if probes.subtitles.is_empty() {
            findings.push(Finding::warn("Subtitles weren't tried: no sample title to ask for."));
        } else if found > 0 {
            working += 1;
            findings.push(Finding::ok(format!("{found} subtitle file(s) for the sample titles.")));
            adds.push("subtitles".into());
        } else {
            let why = probes.subtitles.iter().find_map(|(k, id, p)| probe_problem(&format!("{k} {id}"), p));
            findings.push(Finding::warn(match why {
                Some(w) => format!("Subtitles didn't load. {w}."),
                None => "No subtitles for the sample titles, so this couldn't be confirmed.".into(),
            }));
        }
    }

    let bad = findings.iter().any(|f| f.level == Level::Bad);
    let warn = findings.iter().any(|f| f.level == Level::Warn);
    let (verdict, summary) = if working == 0 {
        (Level::Bad, "Nothing it offers worked in the check.".to_string())
    } else if working == offered && !bad && !warn {
        (Level::Ok, format!("Works with the app: adds {}.", adds.join(", ")))
    } else {
        (Level::Warn, format!("Works in part: adds {}.", adds.join(", ")))
    };
    Report { verdict, summary, adds, findings }
}

/// A report for a manifest that couldn't be read.
pub fn unreadable(why: &str) -> Report {
    Report {
        verdict: Level::Bad,
        summary: "Couldn't read its manifest.".into(),
        adds: Vec::new(),
        findings: vec![Finding::bad(why.to_string())],
    }
}

/// GETs [url] as JSON, giving up after [TIMEOUT].
pub async fn get_json(url: &str) -> Probe {
    let headers = Headers::new();
    headers.set("accept", "application/json").map_err(|e| e.to_string())?;
    let mut init = RequestInit::new();
    init.with_method(Method::Get).with_headers(headers);
    let request = Request::new_with_init(url, &init).map_err(|e| e.to_string())?;
    let fetch = Box::pin(async move {
        let mut response = Fetch::Request(request).send().await.map_err(|e| format!("couldn't reach it ({e})"))?;
        let status = response.status_code();
        let text = response.text().await.unwrap_or_default();
        let body = serde_json::from_str(&text).unwrap_or(Value::Null);
        Ok((status, body))
    });
    match select(fetch, Delay::from(TIMEOUT)).await {
        Either::Left((result, _)) => result,
        Either::Right(_) => Err(format!("no answer in {} seconds", TIMEOUT.as_secs())),
    }
}

fn segment(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>().replace("%3A", ":")
}

/// Reads the manifest at [manifest_url]: its JSON, or a sentence on why not.
pub async fn fetch_manifest(manifest_url: &str) -> Result<Value, String> {
    match get_json(manifest_url).await {
        Err(why) => Err(format!("Couldn't load the manifest: {why}.")),
        Ok((status, _)) if !(200..300).contains(&status) => {
            Err(format!("The manifest address answered {status}. Check the link."))
        }
        Ok((_, body)) if manifest_facts(&body).is_none() => {
            Err("That address doesn't return a Stremio add-on manifest.".into())
        }
        Ok((_, body)) => Ok(body),
    }
}

/// Runs the whole check on an add-on whose manifest is already read.
pub async fn check(manifest_url: &str, manifest: &Value) -> Report {
    let Some(m) = manifest_facts(manifest) else {
        return unreadable("That address doesn't return a Stremio add-on manifest.");
    };
    if m.needs_configuration {
        return judge(&m, &Probes::default());
    }
    let base = base_url(manifest_url);
    let mut probes = Probes::default();
    let has = |r: &str| m.resources.iter().any(|x| x == r);

    // A page of the first few catalogs that work without input.
    let tried: Vec<usize> =
        (0..m.catalogs.len()).filter(|&i| !m.catalogs[i].needs_input).take(CATALOGS_TRIED).collect();
    if has("catalog") {
        let pages = join_all(tried.iter().map(|&i| {
            let c = &m.catalogs[i];
            get_json_owned(format!("{base}/catalog/{}/{}.json", segment(&c.kind), segment(&c.id)))
        }))
        .await;
        probes.catalogs = tried.iter().copied().zip(pages).collect();
    }

    // Sample titles: the first of each type from the catalogs, else IMDb's
    // when it takes IMDb ids.
    let mut titles: Vec<(String, String)> = Vec::new();
    for (i, probe) in &probes.catalogs {
        let Ok((_, body)) = probe else { continue };
        let first = body.get("metas").and_then(Value::as_array).and_then(|a| a.first());
        let Some(id) = first.and_then(|f| f.get("id")).and_then(Value::as_str) else { continue };
        let kind = &m.catalogs[*i].kind;
        if !titles.iter().any(|(k, _)| k == kind) {
            titles.push((kind.clone(), id.to_string()));
        }
    }
    let offered_types: Vec<&str> =
        if m.types.is_empty() { APP_TYPES.to_vec() } else { m.types.iter().map(String::as_str).collect() };
    if takes_imdb(&m) {
        for (kind, id) in [("movie", SAMPLE_MOVIE), ("series", SAMPLE_EPISODE.split(':').next().unwrap_or_default())] {
            if offered_types.contains(&kind) && !titles.iter().any(|(k, _)| k == kind) {
                titles.push((kind.into(), id.into()));
            }
        }
    }

    let meta_urls: Vec<(String, String)> = if has("meta") { titles.clone() } else { Vec::new() };
    // Streams and subtitles are asked for by episode for series.
    let video = |kind: &str, id: &str| {
        if kind == "series" && id.starts_with("tt") && !id.contains(':') { format!("{id}:1:1") } else { id.to_string() }
    };
    let play: Vec<(String, String)> = titles.iter().map(|(k, id)| (k.clone(), video(k, id))).collect();
    let stream_urls = if has("stream") { play.clone() } else { Vec::new() };
    let subtitle_urls = if has("subtitles") { play } else { Vec::new() };

    let fetch_all = |resource: &'static str, list: Vec<(String, String)>| {
        let base = base.to_string();
        async move {
            let answers = join_all(
                list.iter()
                    .map(|(k, id)| get_json_owned(format!("{base}/{resource}/{}/{}.json", segment(k), segment(id)))),
            )
            .await;
            list.into_iter().zip(answers).map(|((k, id), p)| (k, id, p)).collect::<Vec<_>>()
        }
    };
    let (metas, streams, subtitles) = futures_util::join!(
        fetch_all("meta", meta_urls),
        fetch_all("stream", stream_urls),
        fetch_all("subtitles", subtitle_urls)
    );
    probes.metas = metas;
    probes.streams = streams;
    probes.subtitles = subtitles;
    judge(&m, &probes)
}

async fn get_json_owned(url: String) -> Probe {
    get_json(&url).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn manifest_links_are_normalized() {
        assert_eq!(
            normalize_manifest_url(" stremio://v3-cinemeta.strem.io/manifest.json ").as_deref(),
            Some("https://v3-cinemeta.strem.io/manifest.json")
        );
        assert_eq!(
            normalize_manifest_url("https://opensubtitles-v3.strem.io/").as_deref(),
            Some("https://opensubtitles-v3.strem.io/manifest.json")
        );
        assert_eq!(normalize_manifest_url("ftp://x/manifest.json"), None);
        assert_eq!(normalize_manifest_url("not a link"), None);
        assert_eq!(base_url("https://a.example/cfg=1/manifest.json"), "https://a.example/cfg=1");
    }

    fn cinemeta() -> Value {
        json!({
            "id": "com.linvo.cinemeta", "name": "Cinemeta", "version": "3.0.14",
            "resources": ["catalog", "meta", "addon_catalog"], "types": ["movie", "series"], "idPrefixes": ["tt"],
            "catalogs": [
                {"type": "movie", "id": "top", "name": "Popular", "extra": [{"name": "genre"}, {"name": "search"}]},
                {"type": "series", "id": "top", "name": "Popular", "extra": [{"name": "skip"}]},
                {"type": "movie", "id": "search", "name": "Search", "extra": [{"name": "search", "isRequired": true}]}
            ]
        })
    }

    fn page(n: usize, kind: &str) -> Probe {
        Ok((
            200,
            json!({ "metas": (0..n).map(|i| json!({"id": format!("tt{i}"), "type": kind, "name": "x"})).collect::<Vec<_>>() }),
        ))
    }

    #[test]
    fn reads_manifests_leniently() {
        let m = manifest_facts(&cinemeta()).unwrap();
        assert_eq!(m.resources, ["catalog", "meta", "addon_catalog"]);
        assert_eq!(m.catalogs.len(), 3);
        assert!(m.catalogs[2].needs_input && m.catalogs[0].searchable);
        let old = json!({"id": "x", "resources": [{"name": "stream", "types": ["movie"]}],
            "catalogs": [{"type": "movie", "id": "a", "extraSupported": ["search"], "extraRequired": ["search"]}]});
        let m = manifest_facts(&old).unwrap();
        assert_eq!((m.name.as_str(), m.resources.as_slice()), ("x", ["stream".to_string()].as_slice()));
        assert!(m.catalogs[0].needs_input && m.catalogs[0].searchable);
        assert!(manifest_facts(&json!({"name": "no id"})).is_none());
    }

    #[test]
    fn a_working_catalog_addon_passes_with_a_note_on_unused_parts() {
        let m = manifest_facts(&cinemeta()).unwrap();
        let probes = Probes {
            catalogs: vec![(0, page(3, "movie")), (1, page(2, "series"))],
            metas: vec![("movie".into(), "tt0".into(), Ok((200, json!({"meta": {"id": "tt0"}}))))],
            ..Default::default()
        };
        let r = judge(&m, &probes);
        assert_eq!(r.verdict, Level::Ok, "{r:?}");
        assert_eq!(r.adds, ["2 home rows", "search", "details"]);
        assert!(r.findings.iter().any(|f| f.level == Level::Info && f.text.contains("addon_catalog")));
        // A catalog that fails makes it a partial pass.
        let mut broken = probes.clone();
        broken.catalogs[1].1 = Err("no answer in 20 seconds".into());
        assert_eq!(judge(&m, &broken).verdict, Level::Warn);
    }

    #[test]
    fn torrent_only_stream_addons_fail() {
        let m = manifest_facts(
            &json!({"id": "t", "name": "T", "resources": ["stream"], "types": ["movie"], "catalogs": []}),
        )
        .unwrap();
        let probes = Probes {
            streams: vec![(
                "movie".into(),
                SAMPLE_MOVIE.into(),
                Ok((200, json!({"streams": [{"infoHash": "abc"}, {"infoHash": "def", "fileIdx": 1}]}))),
            )],
            ..Default::default()
        };
        let r = judge(&m, &probes);
        assert_eq!(r.verdict, Level::Bad);
        assert!(r.findings.iter().any(|f| f.level == Level::Bad && f.text.contains("2 torrent")));
    }

    #[test]
    fn classifies_streams_like_the_app() {
        let k = stream_kinds(&json!({"streams": [
            {"url": "https://a/b.mp4"}, {"externalUrl": "https://netflix.com/x"}, {"infoHash": "x"}, {"ytId": "abc"}
        ]}));
        assert_eq!(k, StreamKinds { playable: 1, links: 1, torrents: 1, other: 1 });
    }

    #[test]
    fn subtitles_and_failures() {
        let m = manifest_facts(&json!({"id": "os", "name": "OS", "resources": ["subtitles"], "types": ["movie", "series"], "catalogs": []}))
            .unwrap();
        let ok = Probes {
            subtitles: vec![(
                "movie".into(),
                "tt1".into(),
                Ok((200, json!({"subtitles": [{"id": "1", "url": "https://s/1"}]}))),
            )],
            ..Default::default()
        };
        let r = judge(&m, &ok);
        assert_eq!((r.verdict, r.adds.as_slice()), (Level::Ok, ["subtitles".to_string()].as_slice()));
        let down =
            Probes { subtitles: vec![("movie".into(), "tt1".into(), Err("no answer".into()))], ..Default::default() };
        assert_eq!(judge(&m, &down).verdict, Level::Bad);
    }

    #[test]
    fn configuration_and_useless_addons() {
        let m = manifest_facts(
            &json!({"id": "c", "resources": ["stream"], "behaviorHints": {"configurationRequired": true}}),
        )
        .unwrap();
        assert_eq!(judge(&m, &Probes::default()).verdict, Level::Bad);
        let m = manifest_facts(&json!({"id": "c", "resources": ["addon_catalog"]})).unwrap();
        let r = judge(&m, &Probes::default());
        assert!(r.verdict == Level::Bad && r.findings[0].text.contains("addon_catalog"));
    }

    #[test]
    fn own_ids_are_flagged() {
        let m =
            manifest_facts(&json!({"id": "k", "name": "Kitsu", "resources": ["catalog", "meta"], "types": ["anime"],
            "idPrefixes": ["kitsu:"], "catalogs": [{"type": "anime", "id": "trending"}]}))
            .unwrap();
        assert!(!takes_imdb(&m));
        let r = judge(&m, &Probes { catalogs: vec![(0, page(1, "anime"))], ..Default::default() });
        assert_eq!(r.verdict, Level::Warn);
        assert!(r.findings.iter().any(|f| f.text.contains("kitsu:")));
        assert!(r.findings.iter().any(|f| f.text.contains("anime")));
    }
}
