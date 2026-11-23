//! The overview page: users, streams, voice, library, usage and bots.

use std::collections::HashMap;

use couchmates_hub_core::livekit::{Mic, VoiceMember};
use couchmates_hub_core::store::User;
use maud::{Markup, html};
use serde_json::Value;

use crate::layout::{Flash, bars, gb, layout, limit};

pub enum VoiceStatus {
    NotConfigured,
    Error(String),
    Rooms { rooms: usize, people: u64, detail: Vec<(String, Vec<VoiceMember>)> },
}

/// What the overview shows. `system`, `bots` and the `live` streams are the
/// Telegram-Stremio JSON as it came, so new fields don't need code here.
pub struct Overview<'a> {
    pub users: &'a [User],
    pub active_devices: i64,
    pub tgs_error: Option<String>,
    pub system: &'a Value,
    pub bots: &'a Value,
    pub live: Vec<&'a Value>,
    pub voice: VoiceStatus,
    pub week: Vec<f64>,
    pub week_labels: Vec<String>,
    /// (today, this month) in bytes, by Telegram-Stremio token hash.
    pub usage_by_token_hash: HashMap<String, (f64, f64)>,
    /// Title requests waiting for an answer.
    pub pending_requests: i64,
}

fn num(v: &Value, key: &str) -> Option<f64> {
    v.get(key).and_then(Value::as_f64)
}

fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

pub fn page(data: &Overview, flash: Option<&Flash>) -> Markup {
    let Overview { users, system, bots, live, .. } = data;
    let in_voice = match data.voice {
        VoiceStatus::Rooms { people, .. } => people,
        _ => 0,
    };
    let body = html! {
        h1 { "Overview" }
        @if let Some(e) = &data.tgs_error {
            div.flash.bad { (e) ". " a href="/settings" { "Check the connection in Settings" } "." }
        }
        div.grid {
            div.card { div.label { "Users" } div.stat { (users.len()) } div.label { (data.active_devices) " devices active in the last 24 h" } }
            div.card { div.label { "Requests" } div.stat { (data.pending_requests) } div.label { a href="/requests?status=pending" { "waiting for your answer" } } }
            div.card { div.label { "Streaming now" } div.stat { (live.len()) } div.label { "active Telegram-Stremio streams" } }
            div.card {
                div.label { "In voice chat" } div.stat { (in_voice) }
                div.label {
                    @match &data.voice {
                        VoiceStatus::NotConfigured => a href="/settings" { "Set up LiveKit" },
                        VoiceStatus::Error(e) => span.pill.bad { "LiveKit: " (e) },
                        VoiceStatus::Rooms { rooms, .. } => { (rooms) " voice rooms open" },
                    }
                }
            }
            div.card {
                div.label { "Library" }
                div.stat { (num(system, "movies").unwrap_or(0.0)) " · " (num(system, "tv_shows").unwrap_or(0.0)) }
                div.label { "movies · shows" }
            }
        }
        div.card {
            h2 { "Data streamed, last 7 days" }
            (bars(&data.week, &data.week_labels))
            div.row.muted { "Total " (gb(data.week.iter().sum())) ". Collected hourly." }
        }
        div.card {
            h2 { "Usage by user" }
            @if users.is_empty() { p.muted { "No users yet. " a href="/users" { "Add one" } "." } }
            @else {
                table {
                    tr { th { "User" } th { "Today" } th { "This month" } th { "Daily limit" } th { "Monthly limit" } th { "Status" } }
                    @for u in users.iter() {
                        @let usage = u.tgs_token_hash.as_ref().and_then(|h| data.usage_by_token_hash.get(h)).copied().unwrap_or((0.0, 0.0));
                        tr {
                            td { a href=(format!("/users/{}", u.id)) { (u.name) } }
                            td { (gb(usage.0)) } td { (gb(usage.1)) }
                            td { (limit(u.daily_limit_gb)) } td { (limit(u.monthly_limit_gb)) }
                            td { @if u.disabled != 0 { span.pill.bad { "Disabled" } } @else { span.pill.ok { "Active" } } }
                        }
                    }
                }
            }
        }
        @if let VoiceStatus::Rooms { detail, .. } = &data.voice {
            @if !detail.is_empty() {
                div.card {
                    h2 { "Voice chat now" }
                    p.muted { "Straight from LiveKit. A green mic means that person is sending audio; ask someone to talk and watch their speaking light in the app." }
                    table {
                        tr { th { "Watch party room" } th { "People" } }
                        @for (room, members) in detail {
                            tr {
                                td { (room.trim_start_matches("couchmates-")) }
                                td {
                                    @for m in members {
                                        span class=(match m.mic { Mic::On => "pill ok", Mic::Muted => "pill warn", Mic::None => "pill bad" }) {
                                            (m.name) " · " (match m.mic { Mic::On => "mic on", Mic::Muted => "muted", Mic::None => "no mic" })
                                        }
                                        " "
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        @if !live.is_empty() {
            div.card {
                h2 { "Live streams" }
                table {
                    tr { th { "What" } th { "Speed now" } th { "Average" } th { "Sent" } }
                    @for s in live.iter() {
                        tr {
                            td { (text(s, "title").or_else(|| text(s, "file_name")).unwrap_or("—")) }
                            td { (format!("{:.1} Mbps", num(s, "instant_mbps").unwrap_or(0.0))) }
                            td { (format!("{:.1} Mbps", num(s, "avg_mbps").unwrap_or(0.0))) }
                            td { (gb(num(s, "total_bytes").unwrap_or(0.0))) }
                        }
                    }
                }
            }
        }
        @if let Some(list) = bots.get("bot_workloads").and_then(Value::as_array) {
            div.card {
                h2 { "Telegram bots" }
                table {
                    tr { th { "Bot" } th { "Load" } th { "Speed" } th { "Failures" } th { "Status" } }
                    @for b in list {
                        @let status = text(b, "status").unwrap_or("unknown");
                        tr {
                            td { (text(b, "display_name").unwrap_or("Bot")) }
                            td { (num(b, "current_load").unwrap_or(0.0)) }
                            td { (format!("{:.1} Mbps", num(b, "avg_mbps").unwrap_or(0.0))) }
                            td { (num(b, "failures").unwrap_or(0.0)) }
                            td { span.pill.(match status { "healthy" => "ok", "degraded" => "warn", _ => "bad" }) { (status) } }
                        }
                    }
                }
            }
        }
        @if let Some(version) = text(system, "version") {
            p.muted { "Telegram-Stremio " (version) " · up " (text(system, "uptime").unwrap_or("?")) " · " (num(system, "connected_bots").unwrap_or(0.0)) " bots" }
        }
    };
    layout("Overview", "/", flash, body)
}
