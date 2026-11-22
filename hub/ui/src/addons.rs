//! The Add-ons page: public Stremio add-ons the app uses next to
//! Telegram-Stremio, each with its compatibility check.

use couchmates_hub_core::addons::{Level, Report};
use maud::{Markup, html};

use crate::layout::{Flash, layout};

/// One add-on as the page shows it.
pub struct Addon<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub version: &'a str,
    pub description: Option<&'a str>,
    pub manifest_url: &'a str,
    pub enabled: bool,
    pub report: &'a Report,
    /// "5 min ago".
    pub checked: String,
}

/// A well-known add-on offered for one-click adding.
pub struct Suggestion {
    pub name: &'static str,
    pub what: &'static str,
    pub manifest_url: &'static str,
}

/// Official or long-running add-ons whose content is free to watch or is
/// metadata only.
pub const SUGGESTIONS: &[Suggestion] = &[
    Suggestion {
        name: "Cinemeta",
        what: "Stremio's own catalog: popular, new and top-rated movies and shows, with details.",
        manifest_url: "https://v3-cinemeta.strem.io/manifest.json",
    },
    Suggestion {
        name: "OpenSubtitles v3",
        what: "Stremio's subtitles add-on. The app already uses it on its own; adding it here is optional.",
        manifest_url: "https://opensubtitles-v3.strem.io/manifest.json",
    },
    Suggestion {
        name: "WatchHub",
        what: "Stremio's \"where to watch\": links to Netflix, Prime Video and other services that have the title.",
        manifest_url: "https://watchhub.strem.io/manifest.json",
    },
];

fn pill(level: Level) -> Markup {
    match level {
        Level::Ok => html! { span.pill.ok { "Works" } },
        Level::Info => html! { span.pill { "Note" } },
        Level::Warn => html! { span.pill.warn { "Partly" } },
        Level::Bad => html! { span.pill.bad { "Won't work" } },
    }
}

fn finding_mark(level: Level) -> Markup {
    match level {
        Level::Ok => html! { span.pill.ok { "ok" } },
        Level::Info => html! { span.pill { "note" } },
        Level::Warn => html! { span.pill.warn { "check" } },
        Level::Bad => html! { span.pill.bad { "no" } },
    }
}

pub fn page(addons: &[Addon], suggestions: &[&Suggestion], flash: Option<&Flash>) -> Markup {
    let body = html! {
        h1 { "Add-ons" }
        div.card {
            p.muted {
                "Public Stremio add-ons the app uses next to Telegram-Stremio. Their catalogs become home rows after yours, "
                "and their details, streams and subtitles are added to what your server has. The app calls them directly; "
                "changes reach apps the next time they start."
            }
            form method="post" action="/addons" {
                label for="addon_url" { "Manifest link (https://…/manifest.json or stremio://…)" }
                input #addon_url type="text" name="url" required placeholder="https://v3-cinemeta.strem.io/manifest.json";
                div.row { button type="submit" { "Check and add" } }
            }
            p.muted {
                "Each one is checked the way the app would use it. Torrent streams aren't played by the app, so add-ons "
                "that only find torrents are marked as not working."
            }
        }
        @if !suggestions.is_empty() {
            div.card {
                h2 { "Suggested" }
                table {
                    @for s in suggestions {
                        tr {
                            td { b { (s.name) } }
                            td style="white-space:normal" { span.muted { (s.what) } }
                            td {
                                form.inline method="post" action="/addons" {
                                    input type="hidden" name="url" value=(s.manifest_url);
                                    button.secondary type="submit" { "Add" }
                                }
                            }
                        }
                    }
                }
            }
        }
        @if addons.is_empty() {
            div.card { p.muted { "No add-ons yet. The app shows only your Telegram-Stremio catalog." } }
        }
        @for (i, a) in addons.iter().enumerate() {
            div.card {
                div.row style="margin-top:0" {
                    h2 style="margin:0" { (i + 1) ". " (a.name) }
                    @if !a.version.is_empty() { span.muted { "v" (a.version) } }
                    (pill(a.report.verdict))
                    @if a.enabled { span.pill.ok { "On" } } @else { span.pill { "Off" } }
                }
                p { (a.report.summary) }
                @if let Some(d) = a.description { p.muted { (d) } }
                ul style="padding-left:18px;margin:8px 0" {
                    @for f in &a.report.findings {
                        li style="margin:4px 0" { (finding_mark(f.level)) " " (f.text) }
                    }
                }
                p.muted style="word-break:break-all" { (a.manifest_url) " · checked " (a.checked) }
                div.row {
                    form.inline method="post" action=(format!("/addons/{}/{}", a.id, if a.enabled { "disable" } else { "enable" })) {
                        button.secondary type="submit" { @if a.enabled { "Turn off" } @else { "Turn on" } }
                    }
                    form.inline method="post" action=(format!("/addons/{}/check", a.id)) {
                        button.secondary type="submit" { "Check again" }
                    }
                    @if i > 0 {
                        form.inline method="post" action=(format!("/addons/{}/up", a.id)) {
                            button.secondary type="submit" title="Earlier rows and first say in details" { "Move up" }
                        }
                    }
                    @if i + 1 < addons.len() {
                        form.inline method="post" action=(format!("/addons/{}/down", a.id)) {
                            button.secondary type="submit" { "Move down" }
                        }
                    }
                    form.inline method="post" action=(format!("/addons/{}/delete", a.id)) {
                        button.danger type="submit" { "Remove" }
                    }
                }
            }
        }
    };
    layout("Add-ons", "/addons", flash, body)
}
