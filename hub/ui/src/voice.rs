//! The Voice page: how the TURN relay and LiveKit are doing and how much each is used.

use maud::{Markup, PreEscaped, html};

use crate::layout::{Flash, ago, gb, layout};

/// Oracle Cloud's free outbound data per month.
pub const ORACLE_FREE_EGRESS_BYTES: f64 = 10.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0;
/// LiveKit Cloud's free (Build) plan allowances per month.
pub const LIVEKIT_FREE_MINUTES: f64 = 5_000.0;
pub const LIVEKIT_FREE_BYTES: f64 = 50.0 * 1024.0 * 1024.0 * 1024.0;

/// Use over some span. For the relay, `bytes` is in + out; for LiveKit it's the estimate.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Use {
    pub sessions: f64,
    pub minutes: f64,
    pub bytes: f64,
    /// Relay only: what the VM sent out (Oracle counts this).
    pub bytes_out: f64,
}

pub struct Day {
    /// `YYYY-MM-DD`.
    pub day: String,
    pub used: Use,
}

pub enum RelayState {
    /// No relay monitor token yet.
    NotSetUp,
    /// A token exists but no report came yet.
    Waiting,
    Up,
    /// The monitor reports that coturn isn't running.
    CoturnStopped,
    /// No report since this time: the VM or the monitor is down.
    Silent(i64),
}

pub struct Relay<'a> {
    pub state: RelayState,
    /// `host:port` from Settings, when set.
    pub server: Option<&'a str>,
    pub allocations: u32,
    pub relaying: u32,
    pub uptime_secs: i64,
    pub last_report: Option<i64>,
    pub today: Use,
    pub yesterday: Use,
    pub month: Use,
    pub last_month: Use,
    /// Oldest first, the last 14 days.
    pub days: Vec<Day>,
    pub has_token: bool,
    /// A token just made, shown once.
    pub new_token: Option<&'a str>,
}

pub enum LiveKitState {
    NotConfigured,
    Error(String),
    Up { rooms: usize, people: u64 },
}

pub struct LiveKit {
    pub state: LiveKitState,
    /// When the last webhook came, if ever.
    pub webhook_at: Option<i64>,
    pub api_key: Option<String>,
    pub today: Use,
    pub yesterday: Use,
    pub month: Use,
    pub last_month: Use,
    pub days: Vec<Day>,
}

pub struct VoicePage<'a> {
    pub relay: Relay<'a>,
    pub livekit: LiveKit,
    /// Whether apps use direct voice (through the relay) right now, else LiveKit.
    pub direct: bool,
    /// The Hub's own address, for the webhook and the monitor.
    pub hub: &'a str,
    pub now: i64,
}

const STYLE: &str = r#"
.vsec{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:30px 0 14px}
.vsec h2{font:700 20px/1.2 var(--display);letter-spacing:-.015em;margin:0}
.vsec .muted{font-size:13px}
.vgrid .stat{font-size:32px;white-space:nowrap}
.vgrid .stat small{font:600 14px var(--body);color:var(--muted);letter-spacing:0;margin-left:4px}
.delta{display:inline-block;margin-left:8px;padding:1px 8px;border-radius:99px;font:600 12px/1.6 var(--body);vertical-align:middle;background:var(--raised);color:var(--muted);letter-spacing:0}
.delta.up{color:var(--warn);background:color-mix(in srgb,var(--warn) 13%,transparent)}
.delta.down{color:var(--ok);background:color-mix(in srgb,var(--ok) 13%,transparent)}
.meter{height:6px;border-radius:99px;background:var(--raised);overflow:hidden;margin:10px 0 6px}
.meter i{display:block;height:100%;border-radius:99px;background:linear-gradient(90deg,var(--accent),var(--accent-2,var(--accent)))}
.meter.hot i{background:var(--warn)}
.vtwo{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}
.vtwo th,.vtwo td{padding:10px 10px}
.vtwo .card{margin-bottom:0}
.vnote{font-size:13px;color:var(--muted);margin-top:12px}
@media (max-width:980px){.vtwo{grid-template-columns:minmax(0,1fr)}}
"#;

fn minutes(m: f64) -> String {
    let m = m.round() as i64;
    if m >= 600 { format!("{:.1} h", m as f64 / 60.0) } else { format!("{m} min") }
}

fn count(v: f64) -> String {
    format!("{}", v.round() as i64)
}

/// A "+12%" badge comparing [now] with [before]; none when there's nothing to compare.
fn delta(now: f64, before: f64) -> Markup {
    if before <= 0.0 || !now.is_finite() {
        return html! {};
    }
    let pct = ((now - before) / before * 100.0).round();
    let (class, text) = match pct {
        p if p > 0.0 => ("delta up", format!("+{p}%")),
        p if p < 0.0 => ("delta down", format!("{p}%")),
        _ => ("delta", "0%".to_string()),
    };
    html! { span class=(class) title="Compared with all of yesterday" { (text) } }
}

fn meter(used: f64, of: f64) -> Markup {
    let pct = if of > 0.0 { (used / of * 100.0).clamp(0.0, 100.0) } else { 0.0 };
    // Show at least a sliver once anything is used.
    let width = if used > 0.0 { pct.max(1.5) } else { 0.0 };
    html! {
        div class=(if pct >= 80.0 { "meter hot" } else { "meter" }) {
            i style=(format!("width:{width:.1}%")) {}
        }
    }
}

/// Bars for [days], [value] picking the figure and [fmt] writing it.
fn chart(days: &[Day], value: impl Fn(&Use) -> f64, fmt: impl Fn(f64) -> String) -> Markup {
    let values: Vec<f64> = days.iter().map(|d| value(&d.used)).collect();
    let max = values.iter().cloned().fold(0.0, f64::max);
    html! {
        div.bars {
            @for (d, v) in days.iter().zip(&values) {
                div style=(format!("height:{:.0}%", if max > 0.0 { v / max * 100.0 } else { 0.0 })) title=(format!("{}: {}", d.day, fmt(*v))) {}
            }
        }
        @if let (Some(first), Some(_)) = (days.first(), days.last()) {
            div.bar-axis { span { (first.day) } span { "Today" } }
        }
    }
}

fn day_table(days: &[Day], relay: bool) -> Markup {
    html! {
        table {
            tr {
                th { "Day (UTC)" } th { "Sessions" } th { "Minutes" }
                @if relay { th { "Data in + out" } th { "Sent out" } } @else { th { "Data out (est.)" } }
            }
            @for d in days.iter().rev().take(7) {
                tr {
                    td { (d.day) } td { (count(d.used.sessions)) } td { (minutes(d.used.minutes)) }
                    td { (gb(d.used.bytes)) }
                    @if relay { td { (gb(d.used.bytes_out)) } }
                }
            }
        }
    }
}

fn relay_section(r: &Relay, direct: bool, now: i64, hub: &str) -> Markup {
    let pill = match r.state {
        RelayState::NotSetUp => html! { span.pill { "Monitor not set up" } },
        RelayState::Waiting => html! { span.pill.warn { "Waiting for the first report" } },
        RelayState::Up => html! { span.pill.ok { "Up" } },
        RelayState::CoturnStopped => html! { span.pill.bad { "coturn isn't running" } },
        RelayState::Silent(since) => html! { span.pill.bad { "No report since " (ago(now, since)) } },
    };
    html! {
        div.vsec {
            h2 { "Relay" }
            (pill)
            span.muted {
                @if let Some(s) = r.server { "coturn at " code { (s) } } @else { "coturn" }
                @if direct { " · apps use it now" } @else { " · apps use LiveKit now; the relay is idle for Couchmates" }
            }
        }
        div.grid.vgrid {
            div.card {
                div.label { "Relaying now" }
                div.stat { (r.relaying) }
                div.label { (r.allocations) " relay sessions open" }
            }
            div.card {
                div.label { "Minutes today" }
                div.stat { (minutes(r.today.minutes)) (delta(r.today.minutes, r.yesterday.minutes)) }
                div.label { (count(r.today.sessions)) " sessions · yesterday " (minutes(r.yesterday.minutes)) }
            }
            div.card {
                div.label { "Data today" }
                div.stat { (gb(r.today.bytes)) (delta(r.today.bytes, r.yesterday.bytes)) }
                div.label { "in + out · yesterday " (gb(r.yesterday.bytes)) }
            }
            div.card {
                div.label { "This month" }
                div.stat { (minutes(r.month.minutes)) }
                div.label { (count(r.month.sessions)) " sessions · " (gb(r.month.bytes)) " · last month " (minutes(r.last_month.minutes)) }
            }
            div.card {
                div.label { "Oracle free data out" }
                div.stat { (gb(r.month.bytes_out)) small { "/ 10 TB" } }
                (meter(r.month.bytes_out, ORACLE_FREE_EGRESS_BYTES))
                div.label { "sent this month (UTC)" }
            }
        }
        div.vtwo {
            div.card {
                h2 { "Data, last 14 days" }
                (chart(&r.days, |u| u.bytes, gb))
                p.vnote {
                    "DuoDoku uses this relay with the same login, so every figure here includes DuoDoku calls. "
                    "Minutes count each person whose audio went through the relay, so a call where both people are relayed counts twice."
                }
            }
            div.card { h2 { "Last 7 days" } (day_table(&r.days, true)) }
        }
        div.card style="margin-top:16px" {
            h2 { "Relay monitor" }
            p.muted {
                "coturn 4.5.2 has no stats feed, so a small monitor on the relay's server measures it without touching coturn: "
                "relay sessions from the open sockets and bytes from firewall counters. Each minute it sends the totals here. "
                "It only sends; nothing new listens on the server."
            }
            @if let Some(token) = r.new_token {
                div.flash.ok {
                    "The monitor's token. Copy it now: the Hub keeps only a fingerprint and can't show it again."
                    div { span.code style="font-size:15px;letter-spacing:0;word-break:break-all" { (token) } }
                    p.hint { "On the relay server, put it in " code { "/etc/couchmates-relay.conf" } " as " code { "token = …" } " with " code { "hub = " (hub) } "." }
                }
            }
            div.row {
                @if r.has_token { span.pill.ok { "Token set" } } @else { span.pill { "No token" } }
                @if let (Some(at), Some(_)) = (r.last_report, r.has_token.then_some(())) {
                    span.muted { "last report " (ago(now, at)) }
                    @if r.uptime_secs > 0 { span.muted { "· server up " (r.uptime_secs / 86_400) " days" } }
                }
                form.inline method="post" action="/voice/relay-token" {
                    button.secondary type="submit" { @if r.has_token { "Replace token" } @else { "Make a token" } }
                }
                @if r.has_token {
                    form.inline method="post" action="/voice/relay-revoke" {
                        button.danger type="submit" { "Turn off" }
                    }
                }
            }
            p.hint { "Install: copy " code { "hub/dev/relay-agent" } " to the server and run its " code { "install.sh" } ". See its README." }
        }
    }
}

fn livekit_section(l: &LiveKit, direct: bool, now: i64, hub: &str) -> Markup {
    let (pill, people, rooms) = match &l.state {
        LiveKitState::NotConfigured => (html! { span.pill { "Not set up" } }, 0, 0),
        LiveKitState::Error(e) => (html! { span.pill.bad { (e) } }, 0, 0),
        LiveKitState::Up { rooms, people } => (html! { span.pill.ok { "Up" } }, *people, *rooms),
    };
    html! {
        div.vsec {
            h2 { "LiveKit" }
            (pill)
            span.muted { @if direct { "apps use the relay now; LiveKit is idle" } @else { "apps use it now" } }
        }
        @if matches!(l.state, LiveKitState::NotConfigured) {
            div.card { p.muted { "Add your LiveKit server in " a href="/settings#livekit" { "Settings" } " to see it here." } }
        } @else {
            div.grid.vgrid {
                div.card {
                    div.label { "In calls now" }
                    div.stat { (people) }
                    div.label { (rooms) @if rooms == 1 { " room open" } @else { " rooms open" } }
                }
                div.card {
                    div.label { "Minutes today" }
                    div.stat { (minutes(l.today.minutes)) (delta(l.today.minutes, l.yesterday.minutes)) }
                    div.label { (count(l.today.sessions)) " joins · yesterday " (minutes(l.yesterday.minutes)) }
                }
                div.card {
                    div.label { "Minutes this month" }
                    div.stat { (count(l.month.minutes)) small { "/ 5,000" } }
                    (meter(l.month.minutes, LIVEKIT_FREE_MINUTES))
                    div.label { "free plan allowance · last month " (count(l.last_month.minutes)) }
                }
                div.card {
                    div.label { "Data this month (estimate)" }
                    div.stat { (gb(l.month.bytes)) small { "/ 50 GB" } }
                    (meter(l.month.bytes, LIVEKIT_FREE_BYTES))
                    div.label { "sent to listeners · today " (gb(l.today.bytes)) }
                }
            }
            div.vtwo {
                div.card {
                    h2 { "Participant minutes, last 14 days" }
                    (chart(&l.days, |u| u.minutes, minutes))
                    p.vnote {
                        "Minutes come from LiveKit's webhooks and match how LiveKit bills them. LiveKit doesn't report data on the free plan, "
                        "so data is estimated at about 40 kbit/s for each person you hear. LiveKit Cloud's dashboard has the exact figures."
                    }
                }
                div.card { h2 { "Last 7 days" } (day_table(&l.days, false)) }
            }
            div.card style="margin-top:16px" {
                h2 { "LiveKit webhook" }
                @match l.webhook_at {
                    Some(at) => p { span.pill.ok { "Receiving" } " last event " (ago(now, at)) "." },
                    None => p { span.pill.warn { "No events yet" } " Minutes are counted only once LiveKit sends its webhooks here." },
                }
                ol.steps {
                    li { "In LiveKit Cloud, open " b { "Settings → Webhooks" } " and choose " b { "Create new webhook" } "." }
                    li { "URL: " span.address { (hub) "/api/livekit/webhook" } }
                    li { "Signing API key: " @if let Some(k) = &l.api_key { code { (k) } } @else { "the key saved in Settings" } " (the one the Hub uses)." }
                }
            }
        }
    }
}

pub fn page(data: &VoicePage, flash: Option<&Flash>) -> Markup {
    let body = html! {
        style { (PreEscaped(STYLE)) }
        h1 { "Voice" }
        p.muted {
            "Both ways voice chat can run. Apps use "
            @if data.direct { b { "direct voice through your relay" } } @else { b { "LiveKit" } }
            " right now; switch in " a href="/settings#voice-relay" { "Settings" } ". Days run from midnight UTC."
        }
        (relay_section(&data.relay, data.direct, data.now, data.hub))
        (livekit_section(&data.livekit, data.direct, data.now, data.hub))
    };
    layout("Voice", "/voice", flash, body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(new_token: Option<&str>) -> String {
        let used = Use { sessions: 3.0, minutes: 42.0, bytes: 5e8, bytes_out: 3e8 };
        let days = |n: usize| (0..n).map(|i| Day { day: format!("2026-11-{:02}", 10 + i), used }).collect();
        let data = VoicePage {
            relay: Relay {
                state: RelayState::Up,
                server: Some("203.0.113.5:3478"),
                allocations: 2,
                relaying: 1,
                uptime_secs: 86_400 * 3,
                last_report: Some(990),
                today: used,
                yesterday: Use { minutes: 21.0, ..used },
                month: used,
                last_month: Use::default(),
                days: days(14),
                has_token: true,
                new_token,
            },
            livekit: LiveKit {
                state: LiveKitState::Up { rooms: 1, people: 2 },
                webhook_at: None,
                api_key: Some("APIabc".into()),
                today: used,
                yesterday: Use::default(),
                month: used,
                last_month: used,
                days: days(14),
            },
            direct: true,
            hub: "https://hub.example",
            now: 1_000,
        };
        page(&data, None).into_string()
    }

    #[test]
    fn shows_both_backends() {
        let html = sample(Some("cmr_<tok>"));
        assert!(html.contains("Relaying now"));
        assert!(html.contains("DuoDoku"));
        assert!(html.contains("+100%"));
        assert!(html.contains("https://hub.example/api/livekit/webhook"));
        assert!(html.contains("APIabc"));
        assert!(html.contains("cmr_&lt;tok&gt;"));
        assert!(html.contains(r#"action="/voice/relay-token""#));
        assert!(!sample(None).contains("Copy it now"));
    }

    #[test]
    fn deltas_and_minutes() {
        assert_eq!(delta(5.0, 0.0).into_string(), "");
        assert!(delta(5.0, 10.0).into_string().contains("-50%"));
        assert_eq!(minutes(59.6), "60 min");
        assert_eq!(minutes(900.0), "15.0 h");
    }
}
