//! The Requests page: titles friends asked for from the app's search, and the admin's answers. Fulfilling one
//! is a manual job: add the title to Telegram-Stremio, then mark it Added.

use maud::{Markup, html};

use crate::layout::{Flash, layout};

/// One request as the page shows it.
pub struct Request<'a> {
    pub id: &'a str,
    pub kind: &'a str,
    pub title_id: &'a str,
    pub name: &'a str,
    pub year: Option<&'a str>,
    pub poster: Option<&'a str>,
    pub status: &'a str,
    pub note: Option<&'a str>,
    pub requested_by: Vec<String>,
    /// "5 min ago".
    pub asked: String,
    pub changed: String,
}

/// The filter tabs: (query value, label).
pub const FILTERS: &[(&str, &str)] = &[
    ("open", "Waiting"),
    ("pending", "Pending"),
    ("approved", "Approved"),
    ("added", "Added"),
    ("declined", "Declined"),
    ("all", "All"),
];

pub fn status_label(status: &str) -> &'static str {
    match status {
        "pending" => "Pending",
        "approved" => "Approved",
        "added" => "Added",
        "declined" => "Declined",
        _ => "Unknown",
    }
}

fn status_pill(status: &str) -> Markup {
    let label = status_label(status);
    match status {
        "added" => html! { span.pill.ok { (label) } },
        "approved" => html! { span.pill.warn { (label) } },
        "declined" => html! { span.pill.bad { (label) } },
        _ => html! { span.pill { (label) } },
    }
}

/// A link to look the title up, for IMDb ids.
fn imdb_link(title_id: &str) -> Option<String> {
    let digits = title_id.strip_prefix("tt")?;
    (!digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()))
        .then(|| format!("https://www.imdb.com/title/{title_id}/"))
}

pub fn page(requests: &[Request], filter: &str, pending: i64, flash: Option<&Flash>) -> Markup {
    let body = html! {
        h1 { "Requests" }
        div.card {
            p.muted style="margin-top:0" {
                "Titles friends asked for from the app's search because they aren't in the library. "
                "Nothing is downloaded for a request: add the title to Telegram-Stremio yourself, then mark it Added. "
                "Whoever asked sees the status and your note in the app."
            }
            div.row {
                @for (value, label) in FILTERS {
                    @if *value == filter {
                        b { (label) @if *value == "pending" && pending > 0 { " (" (pending) ")" } }
                    } @else {
                        a href=(format!("/requests?status={value}")) {
                            (label) @if *value == "pending" && pending > 0 { " (" (pending) ")" }
                        }
                    }
                }
            }
        }
        @if requests.is_empty() {
            div.card { p.muted { "Nothing here." } }
        }
        @for r in requests {
            div.card {
                div style="display:flex;gap:14px;align-items:flex-start" {
                    @if let Some(p) = r.poster {
                        img src=(p) alt="" loading="lazy" referrerpolicy="no-referrer"
                            style="width:64px;height:96px;object-fit:cover;border-radius:6px;flex:none";
                    }
                    div style="flex:1;min-width:0" {
                        div.row style="margin-top:0" {
                            h2 style="margin:0" {
                                (r.name) @if let Some(y) = r.year { " " span.muted { "(" (y) ")" } }
                            }
                            span.pill { @if r.kind == "series" { "Series" } @else { "Movie" } }
                            (status_pill(r.status))
                        }
                        p.muted style="margin:6px 0" {
                            @if r.requested_by.is_empty() { "Nobody is waiting on it any more" } @else {
                                "Asked by " (r.requested_by.join(", "))
                            }
                            " · " (r.asked)
                            @if r.changed != r.asked { " · changed " (r.changed) }
                            " · "
                            @if let Some(link) = imdb_link(r.title_id) {
                                a href=(link) target="_blank" rel="noopener noreferrer" { (r.title_id) }
                            } @else { code { (r.title_id) } }
                        }
                        form method="post" action=(format!("/requests/{}/status", r.id)) {
                            input type="hidden" name="back" value=(filter);
                            label for=(format!("note-{}", r.id)) { "Note to whoever asked (optional)" }
                            input id=(format!("note-{}", r.id)) type="text" name="note" maxlength="300"
                                value=(r.note.unwrap_or("")) placeholder="Adding it this weekend";
                            div.row {
                                @for (value, label) in [("approved", "Approve"), ("added", "Mark added"), ("declined", "Decline"), ("pending", "Back to pending")] {
                                    @if value != r.status {
                                        button.secondary[value != "approved" && value != "added"] type="submit" name="status" value=(value) { (label) }
                                    } @else {
                                        button.secondary type="submit" name="status" value=(value) title="Keeps the status, saves the note" { "Save note" }
                                    }
                                }
                            }
                        }
                        form.inline method="post" action=(format!("/requests/{}/delete", r.id)) {
                            input type="hidden" name="back" value=(filter);
                            div.row { button.danger type="submit" { "Delete" } }
                        }
                    }
                }
            }
        }
    };
    layout("Requests", "/requests", flash, body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imdb_links_only_for_imdb_ids() {
        assert_eq!(imdb_link("tt0133093").as_deref(), Some("https://www.imdb.com/title/tt0133093/"));
        assert_eq!(imdb_link("kitsu:1"), None);
        assert_eq!(imdb_link("tt"), None);
        assert_eq!(imdb_link("tt12x"), None);
    }

    #[test]
    fn page_escapes_and_offers_every_answer() {
        let r = Request {
            id: "abc",
            kind: "movie",
            title_id: "tt0133093",
            name: "<script>x</script>",
            year: Some("1999"),
            poster: None,
            status: "pending",
            note: None,
            requested_by: vec!["Alice".into(), "Bob".into()],
            asked: "just now".into(),
            changed: "just now".into(),
        };
        let html = page(&[r], "open", 1, None).into_string();
        assert!(!html.contains("<script>x"));
        assert!(html.contains("Asked by Alice, Bob"));
        assert!(html.contains("/requests/abc/status"));
        for answer in ["Approve", "Mark added", "Decline", "Save note"] {
            assert!(html.contains(answer), "{answer}");
        }
    }
}
