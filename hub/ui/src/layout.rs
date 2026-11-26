//! The page frame, styles and small formatting helpers shared by every page.
//!
//! A dark, glassy look in the app's colours: indigo-black under soft
//! periwinkle and violet glows, translucent panels with hairline borders, a
//! floating sidebar with grouped, collapsible sections, Bricolage Grotesque
//! for headings. The Hub's CSP allows no scripts, so everything here works
//! with HTML and CSS alone (the sidebar groups are `<details>`).

use maud::{DOCTYPE, Markup, PreEscaped, html};

pub use couchmates_hub_core::web::Flash;

/// Bricolage Grotesque Bold, cut down to Latin, for headings. OFL licensed.
pub const HEADING_FONT: &[u8] = include_bytes!("../assets/bricolage-bold.woff2");
/// Where the Worker serves [HEADING_FONT], without sign-in.
pub const HEADING_FONT_PATH: &str = "/assets/bricolage-bold.woff2";

pub(crate) const CSS: &str = r#"
@font-face{font-family:"Bricolage Grotesque";src:url(/assets/bricolage-bold.woff2) format("woff2");font-weight:600 800;font-display:swap}
:root{
  --bg:#07080f;--glass:rgba(22,24,42,.62);--glass-2:rgba(255,255,255,.035);--field:rgba(4,5,12,.55);
  --raised:rgba(255,255,255,.06);--line:rgba(255,255,255,.075);--line-strong:rgba(255,255,255,.14);
  --text:#f2f3fb;--muted:#a9adc8;--faint:#6f7493;
  --accent:#7c9cff;--accent-2:#9b7bff;--on-accent:#090a14;--accent-soft:rgba(124,156,255,.13);--accent-line:rgba(124,156,255,.38);
  --ok:#4fe0a5;--warn:#f6c15b;--bad:#ff7d8b;
  --radius:18px;--sheen:inset 0 1px 0 rgba(255,255,255,.05);
  --display:"Bricolage Grotesque","Segoe UI Variable Display","Segoe UI",system-ui,sans-serif;
  --body:"Segoe UI Variable Text","Segoe UI",system-ui,-apple-system,Roboto,"Helvetica Neue",sans-serif;
  --mono:ui-monospace,"Cascadia Mono",Consolas,"SF Mono",monospace;
  color-scheme:dark
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;background:var(--bg)}
body{margin:0;min-height:100vh;color:var(--text);font:14.5px/1.55 var(--body);-webkit-font-smoothing:antialiased;
  background:
    radial-gradient(900px 520px at 18% -8%,rgba(124,156,255,.17),transparent 62%),
    radial-gradient(700px 520px at 104% 4%,rgba(79,224,165,.07),transparent 60%),
    radial-gradient(900px 640px at 92% 108%,rgba(155,123,255,.13),transparent 62%),
    var(--bg);background-attachment:fixed}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline;text-underline-offset:3px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:8px}
code{font:13px var(--mono);background:var(--raised);padding:2px 6px;border-radius:6px}
p{margin:0 0 12px}
h1{font:700 30px/1.15 var(--display);letter-spacing:-.025em;margin:6px 0 24px}
h2{font-size:15px;font-weight:600;margin:0 0 12px;letter-spacing:-.005em}
h3{font-size:14px;font-weight:600;margin:0 0 4px}

/* Frame: a floating glass sidebar, pages beside it. */
.app{display:grid;grid-template-columns:262px minmax(0,1fr);min-height:100vh}
.glass{background:linear-gradient(180deg,rgba(255,255,255,.045),rgba(255,255,255,.012)),var(--glass);border:1px solid var(--line);
  box-shadow:var(--sheen),0 20px 50px -30px rgba(0,0,0,.8);-webkit-backdrop-filter:blur(18px) saturate(1.2);backdrop-filter:blur(18px) saturate(1.2)}
.rail{position:sticky;top:14px;height:calc(100vh - 28px);margin:14px 0 14px 14px;display:flex;flex-direction:column;padding:18px 14px;border-radius:22px;overflow-y:auto}
.brand{display:flex;align-items:center;gap:11px;padding:2px 8px 18px;color:var(--text)}
.brand:hover{text-decoration:none}
.brand svg{width:32px;height:32px;flex:none;border-radius:9px;box-shadow:0 6px 18px -6px rgba(124,120,255,.7)}
.brand b{display:block;font:700 17px/1.1 var(--display);letter-spacing:-.01em}
.brand small{display:block;color:var(--faint);font-size:12px;margin-top:2px}
.navgroup{border-top:1px solid var(--line);padding:12px 0 6px}
.navgroup summary{display:flex;align-items:center;justify-content:space-between;list-style:none;cursor:pointer;padding:2px 8px 8px;color:var(--faint);font-size:12.5px;font-weight:600}
.navgroup summary::-webkit-details-marker{display:none}
.navgroup summary:hover{color:var(--muted)}
.navgroup summary svg{width:14px;height:14px;transition:transform .15s}
.navgroup[open] summary svg{transform:rotate(180deg)}
.navtree{display:flex;flex-direction:column;gap:3px;margin-left:15px;padding-left:10px;border-left:1px solid var(--line)}
.navtree a,.rail-foot button{display:flex;align-items:center;gap:11px;width:100%;padding:8px 11px;border-radius:12px;border:1px solid transparent;color:var(--muted);font:500 14px/1.4 var(--body);background:none;box-shadow:none;cursor:pointer;text-align:left;transition:background-color .15s,color .15s,border-color .15s}
.navtree a:hover,.rail-foot button:hover{background:var(--raised);color:var(--text);text-decoration:none}
.navtree a.on{color:var(--text);border-color:var(--accent-line);background:linear-gradient(90deg,rgba(124,156,255,.24),rgba(124,156,255,.05));box-shadow:0 0 22px -8px rgba(124,156,255,.7)}
.navtree a.on svg{color:var(--accent)}
.navtree svg,.rail-foot svg{width:18px;height:18px;flex:none}
.rail-foot{margin-top:auto;padding-top:12px;border-top:1px solid var(--line)}
main{min-width:0;padding:30px 40px 96px 36px}
.content{max-width:1180px}

/* Panels */
.card{background:linear-gradient(180deg,rgba(255,255,255,.04),rgba(255,255,255,.01)),var(--glass);border:1px solid var(--line);border-radius:var(--radius);
  padding:22px 24px;margin-bottom:16px;overflow-x:auto;box-shadow:var(--sheen)}
.card>h2:first-child{margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:14px;margin-bottom:16px}
.grid .card{margin:0;padding:20px 22px;position:relative;overflow:hidden}
.grid .card::after{content:"";position:absolute;inset:auto -30% -60% auto;width:70%;height:90%;background:radial-gradient(closest-side,rgba(124,156,255,.13),transparent);pointer-events:none}
.grid .card:first-child{border-color:var(--accent-line);box-shadow:var(--sheen),0 0 40px -18px rgba(124,156,255,.8)}
.stat{font:700 36px/1.05 var(--display);letter-spacing:-.03em;margin:10px 0 8px;font-variant-numeric:tabular-nums}
.label{color:var(--muted);font-size:13px}
.muted{color:var(--muted)}

/* Tables */
table{width:100%;border-collapse:separate;border-spacing:0;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:11px 14px;border-bottom:1px solid var(--line);white-space:nowrap;vertical-align:middle}
th{color:var(--faint);font-weight:500;font-size:12.5px;background:var(--glass-2)}
th:first-child{border-radius:10px 0 0 10px}th:last-child{border-radius:0 10px 10px 0}
tr:first-child th{border-bottom:0}
tr:last-child td{border-bottom:0}
tr:hover td{background:rgba(255,255,255,.025)}

/* Forms */
form.inline{display:inline}
label{display:block;margin:18px 0 7px;font-size:13.5px;font-weight:500;color:var(--text)}
input[type=text],input[type=password],input[type=url],input[type=number],textarea,select{width:100%;max-width:480px;padding:10px 13px;border-radius:12px;border:1px solid var(--line-strong);background:var(--field);color:var(--text);font:inherit;transition:border-color .15s,box-shadow .15s}
select option{background:#14162a}
textarea{max-width:560px;resize:vertical;font-family:var(--mono);font-size:13px}
input:focus,textarea:focus,select:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
input::placeholder,textarea::placeholder{color:var(--faint)}
input[type=radio],input[type=checkbox]{accent-color:var(--accent)}
.hint{font-size:12.5px;color:var(--faint);margin-top:7px}
.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:0 20px;max-width:780px}
.form-grid input{max-width:none}
button{display:inline-flex;align-items:center;gap:8px;padding:9px 18px;border-radius:12px;border:1px solid transparent;
  background:linear-gradient(135deg,var(--accent),var(--accent-2));color:var(--on-accent);font:650 14px/1.4 var(--body);cursor:pointer;
  box-shadow:0 8px 22px -10px rgba(124,140,255,.9),inset 0 1px 0 rgba(255,255,255,.25);transition:filter .15s,background-color .15s,border-color .15s}
button:hover{filter:brightness(1.08)}
button.secondary{background:var(--raised);color:var(--text);border-color:var(--line-strong);box-shadow:var(--sheen)}
button.secondary:hover{filter:none;background:rgba(255,255,255,.09)}
button.danger{background:rgba(255,125,139,.06);color:var(--bad);border-color:rgba(255,125,139,.35);box-shadow:none}
button.danger:hover{filter:none;background:rgba(255,125,139,.13)}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:16px}
.actions{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:26px;padding-top:20px;border-top:1px solid var(--line)}

/* Messages, status pills and tabs */
.flash{padding:12px 16px;border-radius:14px;margin-bottom:18px;border:1px solid var(--line);background:var(--glass)}
.flash.ok{border-color:rgba(79,224,165,.35);background:rgba(79,224,165,.08)}
.flash.bad{border-color:rgba(255,125,139,.38);background:rgba(255,125,139,.08)}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:99px;font-size:12px;font-weight:550;line-height:1.65;
  background:var(--raised);color:var(--muted);border:1px solid var(--line-strong);white-space:nowrap}
.pill.ok{color:var(--ok);background:rgba(79,224,165,.1);border-color:rgba(79,224,165,.32)}
.pill.warn{color:var(--warn);background:rgba(246,193,91,.1);border-color:rgba(246,193,91,.32)}
.pill.bad{color:var(--bad);background:rgba(255,125,139,.1);border-color:rgba(255,125,139,.32)}
.pill.ok::before,.pill.warn::before,.pill.bad::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor;box-shadow:0 0 8px currentColor}
.tabs{display:inline-flex;flex-wrap:wrap;gap:4px;padding:4px;border-radius:99px;background:var(--field);border:1px solid var(--line)}
.tabs a{padding:6px 15px;border-radius:99px;color:var(--muted);font-weight:500;border:1px solid transparent}
.tabs a:hover{color:var(--text);text-decoration:none;background:var(--raised)}
.tabs a.on{color:var(--text);background:var(--accent-soft);border-color:var(--accent-line)}
.code{font:600 22px/1.2 var(--mono);letter-spacing:2px;padding:12px 16px;border:1px dashed var(--accent);border-radius:12px;display:inline-block;margin:8px 0;background:var(--field)}
.address{display:inline-block;font:500 14px var(--mono);padding:10px 14px;border:1px solid var(--line-strong);border-radius:12px;background:var(--field);user-select:all;word-break:break-all}

/* The 7-day chart */
.bars{display:flex;align-items:flex-end;gap:8px;height:130px;padding-top:8px}
.bars div{flex:1;background:linear-gradient(180deg,var(--accent),rgba(155,123,255,.5));border-radius:8px 8px 3px 3px;min-height:4px;box-shadow:0 0 18px -6px rgba(124,156,255,.8)}
.bars div:hover{filter:brightness(1.15)}
.bar-axis{display:flex;justify-content:space-between;color:var(--faint);font-size:12px;margin-top:10px;padding-top:8px;border-top:1px solid var(--line)}

/* Settings: grouped section list on the left, one section on the right. The
   open section is the URL's #fragment, so links, back/forward and saved
   forms all land on the right one without scripts. */
.settings{display:grid;grid-template-columns:240px minmax(0,1fr);gap:20px;align-items:start}
.settings-nav{position:sticky;top:14px;display:flex;flex-direction:column;gap:2px;padding:12px 10px;border-radius:var(--radius)}
.settings-nav .group{font-size:12.5px;font-weight:600;color:var(--faint);margin:16px 10px 6px}
.settings-nav .group:first-child{margin-top:4px}
.settings-nav a{display:flex;align-items:center;gap:10px;padding:8px 11px;border-radius:11px;border:1px solid transparent;color:var(--muted);font-weight:500}
.settings-nav a:hover{background:var(--raised);color:var(--text);text-decoration:none}
.dot{width:7px;height:7px;border-radius:50%;margin-left:auto;flex:none;background:var(--line-strong)}
.dot.ok{background:var(--ok);box-shadow:0 0 8px var(--ok)}.dot.warn{background:var(--warn);box-shadow:0 0 8px var(--warn)}.dot.none{background:none}
.set-section{display:none;padding:28px 32px 30px;border-radius:var(--radius);scroll-margin-top:400px}
.set-section:target,.settings-pane:not(:has(.set-section:target)) .set-section:first-child{display:block}
.set-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px}
.set-head h2{font:700 22px/1.2 var(--display);letter-spacing:-.02em;margin:0}
.set-desc{color:var(--muted);max-width:70ch}
.set-desc p{margin:0 0 10px}
.part{margin-top:28px;padding-top:4px}
.part>h3{margin-bottom:2px}
.choices{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;max-width:580px;margin-top:10px}
.choice{display:flex;gap:10px;align-items:flex-start;margin:0;padding:13px 15px;border:1px solid var(--line-strong);border-radius:14px;cursor:pointer;font-weight:400;background:var(--field);transition:border-color .15s,background-color .15s}
.choice:hover{border-color:rgba(255,255,255,.24)}
.choice:has(input:checked){border-color:var(--accent-line);background:linear-gradient(135deg,rgba(124,156,255,.18),rgba(124,156,255,.04));box-shadow:0 0 26px -12px rgba(124,156,255,.8)}
.choice input{margin:3px 0 0}
.choice b{display:block;font-weight:600}
.choice span{display:block;color:var(--muted);font-size:13px}
.choices+.hint{margin-top:10px}
.steps{margin:0;padding-left:20px;color:var(--muted)}
.steps li{margin:4px 0}

/* Sign-in and set-up pages */
.login{max-width:410px;margin:13vh auto;padding:0 16px}
.narrow{max-width:540px;margin:8vh auto;padding:0 16px}
.login .brand,.narrow .brand{padding:0 0 26px}
.login h1,.narrow h1{font-size:26px;margin-bottom:6px}
.login .card,.narrow .card{padding:26px 28px}
.login label:first-of-type{margin-top:0}
.login input{max-width:none}
.qr{background:#fff;display:inline-block;padding:10px;border-radius:12px;margin:8px 0}.qr svg{display:block}

@media (max-width:900px){
  .app{grid-template-columns:minmax(0,1fr)}
  .rail{position:sticky;z-index:2;top:8px;height:auto;margin:8px;flex-direction:row;align-items:center;gap:4px;padding:8px 10px;border-radius:18px;overflow-x:auto}
  .brand{padding:0 6px 0 2px}.brand b,.brand small{display:none}
  .navgroup{display:contents}
  .navgroup summary{display:none}
  .navtree{flex-direction:row;margin:0;padding:0;border:0}
  .navtree a{padding:7px 10px;white-space:nowrap}
  .rail-foot{margin:0 0 0 auto;padding:0;border:0}
  .rail-foot button span{display:none}
  main{padding:18px 14px 72px}
  .settings{grid-template-columns:minmax(0,1fr);gap:14px}
  .settings-nav{position:static;flex-direction:row;overflow-x:auto;gap:4px;padding:6px}
  .settings-nav .group{display:none}
  .settings-nav a{white-space:nowrap}
  .choices{grid-template-columns:1fr}
  .set-section{padding:22px 18px}
}
@media (max-width:600px){.navtree a span{display:none}}
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

/// The sidebar's groups: a heading and its pages.
const NAV: &[(&str, &[(&str, &str)])] = &[
    ("Main", &[("/", "Overview"), ("/users", "Users"), ("/requests", "Requests")]),
    ("Library", &[("/addons", "Add-ons")]),
    ("System", &[("/settings", "Settings")]),
];

const CHEVRON: &str = r#"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>"#;

pub fn layout(title: &str, active: &str, flash: Option<&Flash>, body: Markup) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            (head(title))
            body {
                div.app {
                    aside.rail.glass {
                        (brand())
                        nav aria-label="Hub" {
                            @for (group, pages) in NAV {
                                details.navgroup open {
                                    summary { (group) (PreEscaped(CHEVRON)) }
                                    div.navtree {
                                        @for (href, label) in pages.iter() {
                                            a href=(href) class=[(active == *href).then_some("on")] aria-current=[(active == *href).then_some("page")] {
                                                (icon(href)) span { (label) }
                                            }
                                        }
                                    }
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
