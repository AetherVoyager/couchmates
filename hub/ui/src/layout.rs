//! The page frame, styles and small formatting helpers shared by every page.
//!
//! The look follows the app: indigo-black surfaces from the logo, periwinkle
//! accent, Bricolage Grotesque for headings. A light version follows the
//! system setting. The Hub's CSP allows no scripts, so everything here works
//! with HTML and CSS alone.

use maud::{DOCTYPE, Markup, PreEscaped, html};

pub use couchmates_hub_core::web::Flash;

/// Bricolage Grotesque Bold, cut down to Latin, for headings. OFL licensed.
pub const HEADING_FONT: &[u8] = include_bytes!("../assets/bricolage-bold.woff2");
/// Where the Worker serves [HEADING_FONT], without sign-in.
pub const HEADING_FONT_PATH: &str = "/assets/bricolage-bold.woff2";

pub(crate) const CSS: &str = r#"
@font-face{font-family:"Bricolage Grotesque";src:url(/assets/bricolage-bold.woff2) format("woff2");font-weight:600 800;font-display:swap}
:root{
  --bg:#0d0e18;--rail:#090a12;--panel:#161828;--field:#0f1020;--raised:#232640;--line:#272a42;--line-strong:#3c405e;
  --text:#f1f2fa;--muted:#aeb2cc;--faint:#7a7f9e;--accent:#7c9cff;--on-accent:#0d0e18;--accent-soft:rgba(124,156,255,.14);
  --ok:#4fd39c;--warn:#f3b44b;--bad:#ff7c88;--shadow:none;
  --display:"Bricolage Grotesque","Segoe UI Variable Display","Segoe UI",system-ui,sans-serif;
  --body:"Segoe UI Variable Text","Segoe UI",system-ui,-apple-system,Roboto,"Helvetica Neue",sans-serif;
  --mono:ui-monospace,"Cascadia Mono",Consolas,"SF Mono",monospace;
  color-scheme:dark
}
@media (prefers-color-scheme:light){:root{
  --bg:#f3f4f9;--rail:#fbfbfe;--panel:#fff;--field:#fbfbfe;--raised:#eceef7;--line:#e3e5f0;--line-strong:#c9cde0;
  --text:#14162a;--muted:#555b78;--faint:#868ba6;--accent:#4c68e6;--on-accent:#fff;--accent-soft:rgba(76,104,230,.1);
  --ok:#14875a;--warn:#a06400;--bad:#c8364a;--shadow:0 1px 2px rgba(20,22,42,.05);color-scheme:light
}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:14.5px/1.55 var(--body);-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline;text-underline-offset:3px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
code{font:13px var(--mono);background:var(--raised);padding:2px 6px;border-radius:6px}
p{margin:0 0 12px}
h1{font:700 28px/1.15 var(--display);letter-spacing:-.02em;margin:0 0 24px}
h2{font-size:15px;font-weight:600;margin:0 0 12px;letter-spacing:-.005em}
h3{font-size:14px;font-weight:600;margin:0 0 4px}

/* Frame: a rail on the left like the app, pages on the right. */
.app{display:grid;grid-template-columns:236px minmax(0,1fr);min-height:100vh;background:linear-gradient(90deg,var(--rail) 0 235px,var(--line) 235px 236px,transparent 236px)}
.rail{position:sticky;top:0;height:100vh;display:flex;flex-direction:column;gap:2px;padding:20px 12px;background:var(--rail);border-right:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:11px;padding:2px 10px 22px;color:var(--text)}
.brand:hover{text-decoration:none}
.brand svg{width:30px;height:30px;flex:none;border-radius:8px}
.brand b{display:block;font:700 16.5px/1.1 var(--display);letter-spacing:-.01em}
.brand small{display:block;color:var(--faint);font-size:12px;margin-top:2px}
.nav{display:flex;flex-direction:column;gap:2px}
.nav a,.rail-foot button{display:flex;align-items:center;gap:12px;width:100%;padding:8px 12px;border-radius:9px;color:var(--muted);font:500 14px/1.4 var(--body);background:none;border:0;cursor:pointer;text-align:left;transition:background-color .12s,color .12s}
.nav a:hover,.rail-foot button:hover{background:var(--raised);color:var(--text);text-decoration:none}
.nav a.on{background:var(--accent-soft);color:var(--text)}
.nav a.on svg{color:var(--accent)}
.nav svg,.rail-foot svg{width:18px;height:18px;flex:none}
.rail-foot{margin-top:auto;padding-top:12px;border-top:1px solid var(--line)}
main{min-width:0;padding:40px 48px 96px}
.content{max-width:1120px}

/* Surfaces */
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:20px 22px;margin-bottom:16px;overflow-x:auto;box-shadow:var(--shadow)}
.card>h2:first-child{margin-bottom:14px}
/* The stat strip: one panel split by hairlines, not a row of separate cards. */
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:1px;margin-bottom:16px;background:var(--line);border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:var(--shadow)}
.grid .card{margin:0;padding:18px 20px;border:0;border-radius:0;box-shadow:none}
.stat{font:700 30px/1.1 var(--display);letter-spacing:-.02em;margin:8px 0 6px;font-variant-numeric:tabular-nums}
.label{color:var(--muted);font-size:13px}
.muted{color:var(--muted)}

/* Tables */
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap;vertical-align:middle}
th{color:var(--faint);font-weight:500;font-size:12.5px}
tr:last-child td{border-bottom:0}
tr:hover td{background:color-mix(in srgb,var(--raised) 45%,transparent)}
td:first-child,th:first-child{padding-left:4px}

/* Forms */
form.inline{display:inline}
label{display:block;margin:18px 0 6px;font-size:13.5px;font-weight:500;color:var(--text)}
input[type=text],input[type=password],input[type=url],input[type=number],textarea,select{width:100%;max-width:480px;padding:9px 12px;border-radius:9px;border:1px solid var(--line-strong);background:var(--field);color:var(--text);font:inherit;transition:border-color .12s,box-shadow .12s}
textarea{max-width:560px;resize:vertical;font-family:var(--mono);font-size:13px}
input:focus,textarea:focus,select:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
input::placeholder,textarea::placeholder{color:var(--faint)}
input[type=radio],input[type=checkbox]{accent-color:var(--accent)}
.hint{font-size:12.5px;color:var(--faint);margin-top:6px}
.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:0 20px;max-width:760px}
.form-grid input{max-width:none}
button{display:inline-flex;align-items:center;gap:8px;padding:8px 16px;border-radius:9px;border:1px solid transparent;background:var(--accent);color:var(--on-accent);font:600 14px/1.4 var(--body);cursor:pointer;transition:filter .12s,background-color .12s}
button:hover{filter:brightness(1.08)}
button.secondary{background:var(--raised);color:var(--text);border-color:var(--line)}
button.secondary:hover{filter:none;border-color:var(--line-strong)}
button.danger{background:transparent;color:var(--bad);border-color:color-mix(in srgb,var(--bad) 45%,transparent)}
button.danger:hover{filter:none;background:color-mix(in srgb,var(--bad) 10%,transparent)}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:16px}
.actions{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:24px;padding-top:20px;border-top:1px solid var(--line)}

/* Messages and status */
.flash{padding:12px 16px;border-radius:10px;margin-bottom:18px;border:1px solid var(--line);background:var(--panel)}
.flash.ok{border-color:color-mix(in srgb,var(--ok) 40%,transparent);background:color-mix(in srgb,var(--ok) 9%,var(--panel))}
.flash.bad{border-color:color-mix(in srgb,var(--bad) 40%,transparent);background:color-mix(in srgb,var(--bad) 9%,var(--panel))}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 9px;border-radius:99px;font-size:12px;font-weight:500;line-height:1.6;background:var(--raised);color:var(--muted);white-space:nowrap}
.pill.ok,.pill.warn,.pill.bad{background:color-mix(in srgb,currentColor 13%,transparent)}
.pill.ok{color:var(--ok)}.pill.warn{color:var(--warn)}.pill.bad{color:var(--bad)}
.pill.ok::before,.pill.warn::before,.pill.bad::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
.code{font:600 22px/1.2 var(--mono);letter-spacing:2px;padding:12px 16px;border:1px dashed var(--accent);border-radius:10px;display:inline-block;margin:8px 0;background:var(--field)}
.address{display:inline-block;font:500 14px var(--mono);padding:9px 14px;border:1px solid var(--line-strong);border-radius:9px;background:var(--field);user-select:all;word-break:break-all}

/* The 7-day chart */
.bars{display:flex;align-items:flex-end;gap:6px;height:120px;padding-top:8px}
.bars div{flex:1;background:var(--accent);opacity:.85;border-radius:5px 5px 2px 2px;min-height:3px}
.bars div:hover{opacity:1}
.bar-axis{display:flex;justify-content:space-between;color:var(--faint);font-size:12px;margin-top:8px;padding-top:8px;border-top:1px solid var(--line)}

/* Settings: section list on the left, one section on the right. The section
   shown is the URL's #fragment, so links, back/forward and saved forms all
   land on the right one without scripts. */
.settings{display:grid;grid-template-columns:220px minmax(0,1fr);gap:32px;align-items:start}
.settings-nav{position:sticky;top:24px;display:flex;flex-direction:column;gap:1px}
.settings-nav .group{font-size:12.5px;font-weight:600;color:var(--faint);margin:20px 12px 6px}
.settings-nav .group:first-child{margin-top:4px}
.settings-nav a{display:flex;align-items:center;gap:10px;padding:7px 12px;border-radius:8px;color:var(--muted);font-weight:500}
.settings-nav a:hover{background:var(--raised);color:var(--text);text-decoration:none}
.dot{width:7px;height:7px;border-radius:50%;margin-left:auto;flex:none;background:var(--line-strong)}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.none{background:none}
.set-section{display:none;background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:28px 32px 30px;box-shadow:var(--shadow);scroll-margin-top:400px}
.set-section:target,.settings-pane:not(:has(.set-section:target)) .set-section:first-child{display:block}
.set-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:8px}
.set-head h2{font:700 21px/1.2 var(--display);letter-spacing:-.015em;margin:0}
.set-desc{color:var(--muted);max-width:70ch}
.set-desc p{margin:0 0 10px}
.part{margin-top:28px;padding-top:4px}
.part>h3{margin-bottom:2px}
.part>.hint:first-of-type{margin-top:0}
.choices{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;max-width:560px;margin-top:10px}
.choice{display:flex;gap:10px;align-items:flex-start;margin:0;padding:12px 14px;border:1px solid var(--line-strong);border-radius:10px;cursor:pointer;font-weight:400;background:var(--field)}
.choice:has(input:checked){border-color:var(--accent);background:var(--accent-soft)}
.choice input{margin:3px 0 0}
.choice b{display:block;font-weight:600}
.choice span{display:block;color:var(--muted);font-size:13px}
.choices+.hint{margin-top:10px}
.steps{margin:0;padding-left:20px;color:var(--muted)}
.steps li{margin:4px 0}

/* Sign-in and set-up pages */
.login{max-width:400px;margin:13vh auto;padding:0 16px}
.narrow{max-width:540px;margin:8vh auto;padding:0 16px}
.login .brand,.narrow .brand{padding:0 0 26px}
.login h1,.narrow h1{font-size:24px;margin-bottom:6px}
.login .card,.narrow .card{padding:24px 26px}
.login label:first-of-type{margin-top:0}
.login input{max-width:none}
.qr{background:#fff;display:inline-block;padding:10px;border-radius:10px;margin:8px 0}.qr svg{display:block}

@media (max-width:880px){
  .app{grid-template-columns:minmax(0,1fr);background:none}
  .rail{position:sticky;z-index:2;height:auto;flex-direction:row;align-items:center;gap:6px;padding:10px 12px;border-right:0;border-bottom:1px solid var(--line);overflow-x:auto}
  .brand{padding:0 8px 0 4px}.brand small{display:none}
  .nav{flex-direction:row}
  .nav a{padding:7px 10px;gap:8px;white-space:nowrap}
  .rail-foot{margin:0 0 0 auto;padding:0;border:0}
  .rail-foot button span{display:none}
  main{padding:24px 16px 72px}
  .settings{grid-template-columns:minmax(0,1fr);gap:16px}
  .choices{grid-template-columns:1fr}
  .brand b{display:none}
  .settings-nav{position:static;flex-direction:row;overflow-x:auto;gap:4px;padding-bottom:4px}
  .settings-nav .group{display:none}
  .settings-nav a{white-space:nowrap;border:1px solid var(--line)}
  .set-section{padding:22px 18px}
}
@media (max-width:560px){.nav a span{display:none}}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
"#;

/// The logo: the couch with a play button, on the app icon's gradient.
pub(crate) const LOGO: &str = r##"<svg viewBox="0 0 32 32" aria-hidden="true"><defs><linearGradient id="lg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6e86ff"/><stop offset="1" stop-color="#8a4fff"/></linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#lg)"/><g fill="#fff"><rect x="8.2" y="10" width="15.6" height="9.6" rx="2.6"/><rect x="4.6" y="14.6" width="4.4" height="8.3" rx="2.1"/><rect x="23" y="14.6" width="4.4" height="8.3" rx="2.1"/><rect x="7" y="18.2" width="18" height="4.7" rx="1"/><rect x="7.2" y="22" width="1.9" height="2.6" rx=".8"/><rect x="22.9" y="22" width="1.9" height="2.6" rx=".8"/></g><path d="M14.3 11.7 18.7 14.3 14.3 16.9z" fill="#7b6cff"/></svg>"##;

/// A favicon: the same logo as a data URL (the CSP allows data: images).
const FAVICON: &str = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%237470ff'/%3E%3Cg fill='%23fff'%3E%3Crect x='8.2' y='10' width='15.6' height='9.6' rx='2.6'/%3E%3Crect x='4.6' y='14.6' width='4.4' height='8.3' rx='2.1'/%3E%3Crect x='23' y='14.6' width='4.4' height='8.3' rx='2.1'/%3E%3Crect x='7' y='18.2' width='18' height='4.7' rx='1'/%3E%3C/g%3E%3C/svg%3E";

/// Line icons for the rail, 24×24, drawn with the current colour.
fn icon(name: &str) -> Markup {
    let paths = match name {
        "/" => {
            r#"<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>"#
        }
        "/users" => {
            r#"<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>"#
        }
        "/addons" => {
            r#"<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><path d="M17.5 14v7M14 17.5h7"/>"#
        }
        "/requests" => {
            r#"<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>"#
        }
        "/settings" => r#"<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>"#,
        _ => r#"<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>"#,
    };
    PreEscaped(format!(
        r#"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{paths}</svg>"#
    ))
}

fn head(title: &str) -> Markup {
    html! {
        head {
            meta charset="utf-8";
            meta name="viewport" content="width=device-width, initial-scale=1";
            meta name="color-scheme" content="dark light";
            title { (title) " · Couchmates Hub" }
            link rel="icon" href=(FAVICON);
            link rel="preload" href=(HEADING_FONT_PATH) as="font" type="font/woff2" crossorigin;
            style { (PreEscaped(CSS)) }
        }
    }
}

/// The logo with the product name, linking home.
pub(crate) fn brand() -> Markup {
    html! {
        a.brand href="/" {
            (PreEscaped(LOGO))
            span { b { "Couchmates" } small { "Hub" } }
        }
    }
}

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
            (head(title))
            body {
                div.app {
                    aside.rail {
                        (brand())
                        nav.nav aria-label="Hub" {
                            @for (href, label) in nav {
                                a href=(href) class=[(active == href).then_some("on")] aria-current=[(active == href).then_some("page")] {
                                    (icon(href)) span { (label) }
                                }
                            }
                        }
                        form.rail-foot method="post" action="/logout" {
                            button type="submit" title="Sign out" { (icon("logout")) span { "Sign out" } }
                        }
                    }
                    main {
                        div.content {
                            @if let Some(flash) = flash { (flash_box(flash)) }
                            (body)
                        }
                    }
                }
            }
        }
    }
}

pub fn flash_box(flash: &Flash) -> Markup {
    match flash {
        Flash::Ok(m) => html! { div.flash.ok role="status" { (m) } },
        Flash::Bad(m) => html! { div.flash.bad role="alert" { (m) } },
    }
}

/// A page without the navigation, for steps before the dashboard opens.
pub fn bare(title: &str, body: Markup) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            (head(title))
            body { div.narrow { (brand()) (body) } }
        }
    }
}

/// The sign-in page's frame: centred and narrow.
pub fn sign_in_frame(title: &str, body: Markup) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            (head(title))
            body { div.login { (brand()) (body) } }
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
        @if let Some(first) = labels.first() {
            div.bar-axis { span { (first) } span { "Today" } }
        }
    }
}
