//! How much each voice backend is used, for the Voice page.
//!
//! **Relay (coturn).** coturn 4.5.2 as packaged for Ubuntu has no stats export, so a small monitor on the relay's
//! VM (`hub/dev/relay-agent/`) measures it from outside coturn: relay sockets with `ss`, bytes with nftables
//! counters. Every minute it sends `POST /api/relay/report` with `Authorization: Bearer <relay token>` (made on
//! the Voice page; the Hub keeps only its SHA-256) and a [`RelayReport`]. Nothing on the VM listens for the Hub,
//! so no port is opened. Other apps sharing the relay (and its login) are counted too.
//!
//! **LiveKit.** LiveKit Cloud's analytics API needs the Scale plan, so the Hub counts participant minutes itself
//! from LiveKit's webhooks (`POST /api/livekit/webhook`, signed with the API key the Hub already has). LiveKit
//! doesn't report bytes per connection, so data is estimated from how long people listened to each other.

use couchmates_core::api::OkResponse;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use worker::{Request, Response, Result};

use crate::crypto::{password_matches, sha256_base64, sha256_hex, verify_jwt};
use crate::livekit::LiveKitConfig;
use crate::store::{LiveKitSession, RelayDay, Store, now};
use crate::web::{self, json_error};

/// SHA-256 (hex) of the relay monitor's token. Not a secret by itself.
pub const RELAY_TOKEN_HASH: &str = "relay_token_hash";
/// The relay monitor's last report, as [`RelayStatus`] JSON.
pub const RELAY_STATUS: &str = "relay_status";
/// When the last LiveKit webhook arrived (unix seconds).
pub const LIVEKIT_WEBHOOK_AT: &str = "livekit_webhook_at";

/// The monitor reports every minute; quiet for this long means the VM or the monitor is down.
pub const RELAY_STALE_SECS: i64 = 180;
/// An open LiveKit connection older than this lost its `participant_left` and stops counting.
pub const OPEN_SESSION_CAP_SECS: i64 = 6 * 3600;
/// One person's voice as LiveKit sends it: Opus at about 32 kbit/s plus packet overhead.
pub const AUDIO_BYTES_PER_SEC: f64 = 5_000.0;

/// What the relay monitor sends each minute.
#[derive(Debug, Clone, Deserialize)]
pub struct RelayReport {
    /// `systemctl is-active coturn` said active.
    pub coturn_active: bool,
    /// Relay allocations open now.
    pub allocations: u32,
    /// Of those, how many carried audio in the last minute.
    pub relaying: u32,
    #[serde(default)]
    pub uptime_secs: i64,
    #[serde(default)]
    pub agent_version: String,
    /// Running totals for the last few UTC days.
    #[serde(default)]
    pub days: Vec<RelayDayReport>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RelayDayReport {
    pub day: String,
    pub sessions: i64,
    pub minutes: f64,
    pub bytes_in: f64,
    pub bytes_out: f64,
}

/// The relay's latest state as the Hub keeps it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RelayStatus {
    pub coturn_active: bool,
    pub allocations: u32,
    pub relaying: u32,
    pub uptime_secs: i64,
    pub agent_version: String,
    pub received_at: i64,
}

fn is_day(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
}

/// The days of a report worth saving: well-formed, sane numbers, at most a week.
pub fn clean_days(days: &[RelayDayReport]) -> Vec<RelayDay> {
    let ok = |v: f64| v.is_finite() && v >= 0.0 && v < 1e15;
    days.iter()
        .filter(|d| is_day(&d.day) && d.sessions >= 0 && ok(d.minutes) && ok(d.bytes_in) && ok(d.bytes_out))
        .take(7)
        .map(|d| RelayDay {
            day: d.day.clone(),
            sessions: d.sessions.min(10_000_000),
            minutes: d.minutes,
            bytes_in: d.bytes_in,
            bytes_out: d.bytes_out,
        })
        .collect()
}

/// `POST /api/relay/report`
pub async fn relay_report(mut req: Request, store: &Store) -> Result<Response> {
    let Some(expected) = store.setting(RELAY_TOKEN_HASH).await? else {
        return json_error("No relay token is set up. Make one on the Hub's Voice page.", 401);
    };
    match web::bearer(&req) {
        Some(token) if password_matches(&sha256_hex(&token), &expected) => {}
        _ => return json_error("Wrong relay token.", 401),
    }
    let Ok(report) = req.json::<RelayReport>().await else {
        return json_error("That isn't a relay report.", 400);
    };
    let now = now();
    store.save_relay_days(&clean_days(&report.days), now).await?;
    let status = RelayStatus {
        coturn_active: report.coturn_active,
        allocations: report.allocations.min(1_000_000),
        relaying: report.relaying.min(1_000_000),
        uptime_secs: report.uptime_secs.max(0),
        agent_version: report.agent_version.chars().take(20).collect(),
        received_at: now,
    };
    store.set_setting(RELAY_STATUS, Some(&serde_json::to_string(&status).unwrap_or_default())).await?;
    web::json(&OkResponse { ok: true }, 200)
}

pub async fn relay_status(store: &Store) -> Result<Option<RelayStatus>> {
    Ok(store.setting(RELAY_STATUS).await?.and_then(|s| serde_json::from_str(&s).ok()))
}

/// A webhook from LiveKit, from its JSON.
#[derive(Debug, PartialEq)]
pub enum LiveKitEvent {
    Joined { sid: String, room: String, identity: String, at: i64 },
    Left { sid: String, room: String, identity: String, joined_at: i64, at: i64 },
    RoomFinished { room: String, at: i64 },
    Other,
}

/// LiveKit sends int64s as strings or numbers, depending on the server.
fn int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn text(v: &Value, path: &[&str]) -> String {
    let mut cur = v;
    for key in path {
        match cur.get(key) {
            Some(next) => cur = next,
            None => return String::new(),
        }
    }
    cur.as_str().unwrap_or_default().to_string()
}

pub fn parse_livekit_event(body: &Value, now: i64) -> LiveKitEvent {
    let at = int(body.get("createdAt").or_else(|| body.get("created_at"))).filter(|t| *t > 0).unwrap_or(now);
    let room = text(body, &["room", "name"]);
    let sid = text(body, &["participant", "sid"]);
    let identity = text(body, &["participant", "identity"]);
    let joined = body
        .get("participant")
        .and_then(|p| int(p.get("joinedAt").or_else(|| p.get("joined_at"))))
        .filter(|t| *t > 0)
        .unwrap_or(at);
    match body.get("event").and_then(Value::as_str).unwrap_or_default() {
        "participant_joined" if !sid.is_empty() => LiveKitEvent::Joined { sid, room, identity, at: joined },
        "participant_left" | "participant_connection_aborted" if !sid.is_empty() => {
            LiveKitEvent::Left { sid, room, identity, joined_at: joined, at }
        }
        "room_finished" if !room.is_empty() => LiveKitEvent::RoomFinished { room, at },
        _ => LiveKitEvent::Other,
    }
}

/// Whether [authorization] is LiveKit's signature over [body] made with [config]'s key.
pub fn livekit_signature_ok(config: &LiveKitConfig, authorization: &str, body: &[u8], now: i64) -> bool {
    let token = authorization.trim().trim_start_matches("Bearer ").trim();
    let Some(claims) = verify_jwt(&config.api_secret, token, now) else {
        return false;
    };
    claims.get("iss").and_then(Value::as_str) == Some(config.api_key.as_str())
        && claims.get("sha256").and_then(Value::as_str) == Some(sha256_base64(body).as_str())
}

/// `POST /api/livekit/webhook`
pub async fn livekit_webhook(mut req: Request, store: &Store) -> Result<Response> {
    let Some(config) = LiveKitConfig::load(store).await? else {
        return json_error("LiveKit isn't set up on this Hub.", 404);
    };
    let authorization = req.headers().get("authorization")?.unwrap_or_default();
    let body = req.bytes().await?;
    let now = now();
    if !livekit_signature_ok(&config, &authorization, &body, now) {
        return json_error("That webhook isn't signed with this Hub's LiveKit key.", 401);
    }
    let Ok(json) = serde_json::from_slice::<Value>(&body) else {
        return json_error("That isn't JSON.", 400);
    };
    match parse_livekit_event(&json, now) {
        LiveKitEvent::Joined { sid, room, identity, at } => store.livekit_joined(&sid, &room, &identity, at).await?,
        LiveKitEvent::Left { sid, room, identity, joined_at, at } => {
            store.livekit_left(&sid, &room, &identity, joined_at, at).await?
        }
        LiveKitEvent::RoomFinished { room, at } => store.livekit_room_finished(&room, at).await?,
        LiveKitEvent::Other => {}
    }
    store.set_setting(LIVEKIT_WEBHOOK_AT, Some(&now.to_string())).await?;
    web::json(&OkResponse { ok: true }, 200)
}

/// LiveKit use within a span of time.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct LiveKitUse {
    /// Participant minutes, as LiveKit bills them.
    pub minutes: f64,
    /// Connections that started in the span.
    pub sessions: u32,
    /// Estimated data LiveKit sent out (each listener receives each talker).
    pub est_bytes: f64,
}

/// LiveKit use between [start] and [end], counting open connections up to [now].
pub fn livekit_use(sessions: &[LiveKitSession], start: i64, end: i64, now: i64) -> LiveKitUse {
    let span = |s: &LiveKitSession| {
        let stop = s.left_at.unwrap_or(now.min(s.joined_at + OPEN_SESSION_CAP_SECS)).max(s.joined_at);
        (s.joined_at.max(start), stop.min(end))
    };
    let mut out = LiveKitUse::default();
    let mut listening_secs = 0.0;
    for (i, a) in sessions.iter().enumerate() {
        let (a0, a1) = span(a);
        if a.joined_at >= start && a.joined_at < end {
            out.sessions += 1;
        }
        if a1 <= a0 {
            continue;
        }
        out.minutes += (a1 - a0) as f64 / 60.0;
        for (j, b) in sessions.iter().enumerate() {
            if i == j || a.room != b.room {
                continue;
            }
            let (b0, b1) = span(b);
            listening_secs += (a1.min(b1) - a0.max(b0)).max(0) as f64;
        }
    }
    out.est_bytes = listening_secs * AUDIO_BYTES_PER_SEC;
    out
}

/// `YYYY-MM-DD` of the UTC day holding [t].
pub fn day_label(t: i64) -> String {
    let days = t.div_euclid(86_400);
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn s(room: &str, joined: i64, left: Option<i64>) -> LiveKitSession {
        LiveKitSession { room: room.into(), joined_at: joined, left_at: left }
    }

    #[test]
    fn livekit_minutes_and_listening() {
        // Two people together for 10 minutes, a third alone in another room for 5.
        let list = vec![s("a", 0, Some(600)), s("a", 0, Some(600)), s("b", 100, Some(400))];
        let u = livekit_use(&list, 0, 86_400, 1_000);
        assert_eq!(u.minutes, 25.0);
        assert_eq!(u.sessions, 3);
        assert_eq!(u.est_bytes, 1200.0 * AUDIO_BYTES_PER_SEC);
        // Clipped to the span; an open connection counts up to now.
        let u = livekit_use(&[s("a", 0, None)], 300, 86_400, 900);
        assert_eq!(u.minutes, 10.0);
        assert_eq!(u.sessions, 0);
        // A forgotten connection stops counting after the cap.
        let u = livekit_use(&[s("a", 0, None)], 0, i64::MAX, 100 * 3600);
        assert_eq!(u.minutes, (OPEN_SESSION_CAP_SECS / 60) as f64);
    }

    #[test]
    fn reads_livekit_webhooks() {
        let joined = json!({"event": "participant_joined", "room": {"name": "couchmates-AB"},
            "participant": {"sid": "PA_1", "identity": "u:d", "joinedAt": "1700000000"}, "createdAt": "1700000001"});
        assert_eq!(
            parse_livekit_event(&joined, 5),
            LiveKitEvent::Joined {
                sid: "PA_1".into(),
                room: "couchmates-AB".into(),
                identity: "u:d".into(),
                at: 1_700_000_000
            }
        );
        let left = json!({"event": "participant_left", "room": {"name": "r"},
            "participant": {"sid": "PA_1", "identity": "u", "joinedAt": 10}, "createdAt": 70});
        assert_eq!(
            parse_livekit_event(&left, 5),
            LiveKitEvent::Left { sid: "PA_1".into(), room: "r".into(), identity: "u".into(), joined_at: 10, at: 70 }
        );
        let done = json!({"event": "room_finished", "room": {"name": "r"}});
        assert_eq!(parse_livekit_event(&done, 9), LiveKitEvent::RoomFinished { room: "r".into(), at: 9 });
        assert_eq!(parse_livekit_event(&json!({"event": "track_published"}), 9), LiveKitEvent::Other);
    }

    #[test]
    fn checks_livekit_signatures() {
        let config = LiveKitConfig { url: "wss://x".into(), api_key: "APIkey".into(), api_secret: "sec".into() };
        let body = br#"{"event":"room_started"}"#;
        let token = crate::crypto::sign_jwt(
            "sec",
            &json!({"iss": "APIkey", "sha256": sha256_base64(body), "exp": 2_000, "nbf": 0}),
        );
        assert!(livekit_signature_ok(&config, &token, body, 1_000));
        assert!(livekit_signature_ok(&config, &format!("Bearer {token}"), body, 1_000));
        assert!(!livekit_signature_ok(&config, &token, b"{}", 1_000));
        let other = LiveKitConfig { api_key: "APIother".into(), ..config };
        assert!(!livekit_signature_ok(&other, &token, body, 1_000));
    }

    #[test]
    fn relay_reports_are_cleaned() {
        let d = |day: &str, minutes: f64| RelayDayReport {
            day: day.into(),
            sessions: 2,
            minutes,
            bytes_in: 1.0,
            bytes_out: 2.0,
        };
        let kept =
            clean_days(&[d("2026-11-26", 3.0), d("26-11-2026", 1.0), d("2026-11-25", -1.0), d("2026-11-2x", 1.0)]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].day, "2026-11-26");
    }

    #[test]
    fn day_labels() {
        assert_eq!(day_label(0), "1970-01-01");
        assert_eq!(day_label(1_795_537_500), "2026-11-24");
        assert_eq!(day_label(1_709_208_000), "2024-02-29");
    }
}
