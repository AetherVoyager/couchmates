//! The page frame, styles and small formatting helpers shared by every page.

use maud::{DOCTYPE, Markup, PreEscaped, html};

pub use couchmates_hub_core::web::Flash;

pub(crate) const CSS: &str = r#"
:root{--bg:#0f1115;--panel:#171a21;--line:#262b36;--text:#e7e9ee;--muted:#9aa3b2;--accent:#7c9cff;--ok:#3ecf8e;--warn:#f5a524;--bad:#f06a6a;color-scheme:dark}
@media (prefers-color-scheme:light){:root{--bg:#f6f7f9;--panel:#fff;--line:#e3e6eb;--text:#151821;--muted:#5d6678;--accent:#3d5afe;color-scheme:light}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
header{display:flex;align-items:center;gap:20px;padding:14px 24px;border-bottom:1px solid var(--line);background:var(--panel);flex-wrap:wrap}
header .brand{font-weight:700;font-size:17px}header nav{display:flex;gap:16px;flex:1;flex-wrap:wrap}header nav a{color:var(--muted)}header nav a.on{color:var(--text);font-weight:600}
main{max-width:1100px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:22px;margin:0 0 18px}h2{font-size:16px;margin:0 0 12px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin-bottom:18px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:18px;overflow-x:auto}
.grid .card{margin:0}.stat{font-size:26px;font-weight:700}.label{color:var(--muted);font-size:13px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap}th{color:var(--muted);font-weight:500;font-size:13px}
form.inline{display:inline}label{display:block;margin:10px 0 4px;color:var(--muted);font-size:13px}
input[type=text],input[type=password],input[type=url],input[type=number]{width:100%;max-width:460px;padding:9px 11px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--text);font:inherit}
button{padding:8px 14px;border-radius:8px;border:1px solid var(--line);background:var(--accent);color:#fff;font:inherit;cursor:pointer}
button.secondary{background:transparent;color:var(--text)}button.danger{background:transparent;color:var(--bad);border-color:var(--bad)}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:12px}
.flash{padding:10px 14px;border-radius:8px;margin-bottom:16px;border:1px solid var(--line)}.flash.ok{border-color:var(--ok)}.flash.bad{border-color:var(--bad)}
.pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;border:1px solid var(--line)}.pill.ok{color:var(--ok);border-color:var(--ok)}.pill.bad{color:var(--bad);border-color:var(--bad)}.pill.warn{color:var(--warn);border-color:var(--warn)}
.code{font:600 24px/1.2 ui-monospace,Consolas,monospace;letter-spacing:2px;padding:14px;border:1px dashed var(--accent);border-radius:10px;display:inline-block;margin:8px 0}
.muted{color:var(--muted)}.bars{display:flex;align-items:flex-end;gap:4px;height:80px}.bars div{flex:1;background:var(--accent);border-radius:3px 3px 0 0;min-height:2px}
.login{max-width:380px;margin:12vh auto;padding:0 16px}
.narrow{max-width:520px;margin:8vh auto;padding:0 16px}.qr{background:#fff;display:inline-block;padding:10px;border-radius:10px;margin:8px 0}.qr svg{display:block}
"#;

pub fn layout(title: &str, active: &str, flash: Option<&Flash>, body: Markup) -> Markup {
    let nav = [
        ("/", "Overview"),
        ("/users", "Users"),
        ("/addons", "Add-ons"),
        ("/requests", "Requests"),
        ("/settings", "Settings"),
    ];
    html! {
        (DOCTYPE)
        html lang="en" {
            head {
                meta charset="utf-8";
                meta name="viewport" content="width=device-width, initial-scale=1";
                title { (title) " · Couchmates Hub" }
                style { (PreEscaped(CSS)) }
            }
            body {
                header {
                    span.brand { "Couchmates Hub" }
                    nav {
                        @for (href, label) in nav {
                            a href=(href) class=[(active == href).then_some("on")] { (label) }
                        }
                    }
                    form.inline method="post" action="/logout" { button.secondary type="submit" { "Sign out" } }
                }
                main {
                    @if let Some(flash) = flash { (flash_box(flash)) }
                    (body)
                }
            }
        }
    }
}

pub fn flash_box(flash: &Flash) -> Markup {
    match flash {
        Flash::Ok(m) => html! { div.flash.ok { (m) } },
        Flash::Bad(m) => html! { div.flash.bad { (m) } },
    }
}

/// A page without the navigation, for steps before the dashboard opens.
pub fn bare(title: &str, body: Markup) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            head {
                meta charset="utf-8";
                meta name="viewport" content="width=device-width, initial-scale=1";
                title { (title) " · Couchmates Hub" }
                style { (PreEscaped(CSS)) }
            }
            body { div.narrow { (body) } }
        }
    }
}

pub fn gb(bytes: f64) -> String {
    let gb = bytes / 1_073_741_824.0;
    if gb >= 100.0 {
        format!("{gb:.0} GB")
    } else if gb >= 1.0 {
        format!("{gb:.1} GB")
    } else {
        format!("{:.0} MB", bytes / 1_048_576.0)
    }
}

pub fn limit(gb: f64) -> String {
    if gb > 0.0 { format!("{gb} GB") } else { "No limit".into() }
}

pub fn ago(now: i64, then: i64) -> String {
    let d = (now - then).max(0);
    match d {
        0..=59 => "just now".into(),
        60..=3599 => format!("{} min ago", d / 60),
        3600..=86_399 => format!("{} h ago", d / 3600),
        _ => format!("{} days ago", d / 86_400),
    }
}

/// A small bar chart, tallest bar = full height.
pub fn bars(values: &[f64], labels: &[String]) -> Markup {
    let max = values.iter().cloned().fold(0.0, f64::max).max(1.0);
    html! {
        div.bars {
            @for (i, v) in values.iter().enumerate() {
                div style=(format!("height:{:.0}%", v / max * 100.0)) title=(format!("{}: {}", labels.get(i).map(String::as_str).unwrap_or(""), gb(*v))) {}
            }
        }
    }
}
