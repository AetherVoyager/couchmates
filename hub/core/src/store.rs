//! D1 access: settings, sessions, users, devices and usage history.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use worker::wasm_bindgen::JsValue;
use worker::{D1Database, Env, Result};

use crate::crypto::{Sealer, random_id, sha256_hex};

/// Days an Added or Declined request stays before the hourly cleanup deletes it.
pub const ANSWERED_REQUEST_DAYS: i64 = 60;

pub fn now() -> i64 {
    (worker::Date::now().as_millis() / 1000) as i64
}

pub struct Store {
    pub db: D1Database,
    pub sealer: Sealer,
}

fn s(value: &str) -> JsValue {
    JsValue::from_str(value)
}

fn n(value: f64) -> JsValue {
    JsValue::from_f64(value)
}

/// Setting keys whose values are encrypted.
const SECRET_KEYS: &[&str] = &[
    "tgs_password",
    "tgs_cookie",
    "livekit_secret",
    "totp_secret",
    "totp_pending",
    "github_token",
    "trakt_client_secret",
    "tmdb_key",
    "bot_webhook_url",
];

/// Secret keys an earlier version stored unencrypted. A value that doesn't
/// open is read as it is, and gets encrypted the next time it's saved.
const ONCE_PLAINTEXT: &[&str] = &["trakt_client_secret"];

#[derive(Debug, Clone, Deserialize)]
pub struct User {
    pub id: String,
    pub name: String,
    pub username: Option<String>,
    pub password_hash: Option<String>,
    pub tgs_token_enc: Option<String>,
    pub tgs_token_hash: Option<String>,
    pub daily_limit_gb: f64,
    pub monthly_limit_gb: f64,
    pub disabled: i64,
    pub created_at: i64,
    /// Set when the user has a profile picture.
    #[serde(default)]
    pub photo_version: Option<i64>,
    /// 1 for a chat admin (verified badge, may moderate the chat).
    #[serde(default)]
    pub chat_admin: i64,
    /// Can't send chat messages until then (Unix seconds).
    #[serde(default)]
    pub chat_muted_until: Option<i64>,
}

impl User {
    pub fn is_chat_admin(&self) -> bool {
        self.chat_admin != 0
    }

    /// When this user's chat mute ends, if they're muted at [now].
    pub fn muted_until(&self, now: i64) -> Option<i64> {
        self.chat_muted_until.filter(|until| *until > now)
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Device {
    pub id: String,
    pub user_id: String,
    pub name: String,
    pub created_at: i64,
    pub last_seen: i64,
}

/// A linked tracker account, with its tokens opened.
#[derive(Debug, Clone)]
pub struct TrackerLink {
    pub service: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<i64>,
    pub username: Option<String>,
}

/// A device's presence, with its user's name.
#[derive(Debug, Clone, Deserialize)]
pub struct PresenceRow {
    pub device_id: String,
    pub user_id: String,
    pub name: String,
    pub seen_at: i64,
    /// NowWatching JSON.
    pub watching: Option<String>,
    pub watching_since: Option<i64>,
    #[serde(default)]
    pub photo_version: Option<i64>,
    /// The address the device last reported from.
    #[serde(default)]
    pub ip: Option<String>,
    #[serde(default)]
    pub device_name: Option<String>,
    #[serde(default)]
    pub chat_admin: i64,
}

/// A public Stremio add-on from the Add-ons page, with its URL opened.
#[derive(Debug, Clone)]
pub struct AddonRow {
    pub id: String,
    pub manifest_url: String,
    pub name: String,
    pub position: i64,
    pub enabled: bool,
    /// The manifest JSON as last read.
    pub manifest: String,
    /// The compatibility check ([`crate::addons::Report`]) as JSON.
    pub report: String,
    pub checked_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
struct AddonDbRow {
    id: String,
    url_enc: String,
    name: String,
    position: i64,
    enabled: i64,
    manifest: String,
    report: String,
    checked_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
struct AddonIdRow {
    #[allow(dead_code)]
    id: String,
}

#[derive(Debug, Clone, Deserialize)]
struct IdRow {
    id: i64,
}

/// A chat message with its sender's name and picture.
#[derive(Debug, Clone, Deserialize)]
pub struct ChatRow {
    pub id: i64,
    pub channel: String,
    pub sender: String,
    /// The other person of a private chat.
    #[serde(default)]
    pub recipient: Option<String>,
    pub from_name: String,
    #[serde(default)]
    pub from_photo: Option<i64>,
    #[serde(default)]
    pub from_admin: i64,
    pub text: String,
    pub sent_at: i64,
}

/// A channel's latest message, the other person of a private chat, and how
/// many messages from others the user hasn't read (counted up to 100).
#[derive(Debug, Clone, Deserialize)]
pub struct ChatChannelRow {
    pub id: i64,
    pub channel: String,
    pub sender: String,
    #[serde(default)]
    pub recipient: Option<String>,
    pub from_name: String,
    #[serde(default)]
    pub from_photo: Option<i64>,
    #[serde(default)]
    pub from_admin: i64,
    pub text: String,
    pub sent_at: i64,
    #[serde(default)]
    pub other_id: Option<String>,
    #[serde(default)]
    pub other_name: Option<String>,
    #[serde(default)]
    pub other_photo: Option<i64>,
    #[serde(default)]
    pub other_admin: i64,
    pub unread: i64,
}

impl ChatChannelRow {
    /// The channel's latest message.
    pub fn last(&self) -> ChatRow {
        ChatRow {
            id: self.id,
            channel: self.channel.clone(),
            sender: self.sender.clone(),
            recipient: self.recipient.clone(),
            from_name: self.from_name.clone(),
            from_photo: self.from_photo,
            from_admin: self.from_admin,
            text: self.text.clone(),
            sent_at: self.sent_at,
        }
    }
}

/// The columns of a [ChatRow], from `chat_messages m`.
const CHAT_SELECT: &str = "SELECT m.id, m.channel, m.sender, m.recipient, COALESCE(us.name, 'Someone') AS from_name, \
     ps.version AS from_photo, COALESCE(us.chat_admin, 0) AS from_admin, m.text, m.sent_at FROM chat_messages m LEFT JOIN users us ON us.id = m.sender \
     LEFT JOIN photos ps ON ps.user_id = m.sender";

/// Unread messages in `m.channel` for user ?1, counted up to 100.
const CHAT_UNREAD: &str = "(SELECT COUNT(*) FROM (SELECT 1 FROM chat_messages c WHERE c.channel = m.channel \
     AND c.sender != ?1 AND c.id > COALESCE((SELECT last_read FROM chat_reads r WHERE r.user_id = ?1 \
     AND r.channel = m.channel), 0) LIMIT 100)) AS unread";

#[derive(Debug, Clone, Deserialize)]
pub struct JoinRow {
    pub id: String,
    pub from_user: String,
    pub from_name: String,
    pub to_user: String,
    pub to_name: String,
    pub title: String,
    pub status: String,
    pub room: Option<String>,
    pub created_at: i64,
    pub answered_at: Option<i64>,
    #[serde(default)]
    pub from_photo: Option<i64>,
    #[serde(default)]
    pub to_photo: Option<i64>,
}

const JOIN_SELECT: &str = "SELECT r.id, r.from_user, uf.name AS from_name, r.to_user, ut.name AS to_name, r.title, \
     r.status, r.room, r.created_at, r.answered_at, pf.version AS from_photo, pt.version AS to_photo \
     FROM join_requests r JOIN users uf ON uf.id = r.from_user JOIN users ut ON ut.id = r.to_user \
     LEFT JOIN photos pf ON pf.user_id = r.from_user LEFT JOIN photos pt ON pt.user_id = r.to_user";

/// A title friends asked for, with who asked (a JSON array of names, first asker first) and whether the user
/// the query was made for is among them.
#[derive(Debug, Clone, Deserialize)]
pub struct MediaRequestRow {
    pub id: String,
    pub kind: String,
    pub title_id: String,
    pub name: String,
    #[serde(default)]
    pub year: Option<String>,
    #[serde(default)]
    pub poster: Option<String>,
    #[serde(default)]
    pub season: Option<u32>,
    #[serde(default)]
    pub episode: Option<u32>,
    #[serde(default)]
    pub episode_title: Option<String>,
    pub status: String,
    #[serde(default)]
    pub note: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub requested_by: String,
    pub mine: i64,
}

impl MediaRequestRow {
    pub fn requester_names(&self) -> Vec<String> {
        serde_json::from_str(&self.requested_by).unwrap_or_default()
    }
}

/// The columns of a [MediaRequestRow] from `media_requests r`, for user ?1.
const REQUEST_SELECT: &str = "SELECT r.id, r.kind, r.title_id, r.name, r.year, r.poster, r.season, r.episode, \
     r.episode_title, r.status, r.note, \
     r.created_at, r.updated_at, (SELECT json_group_array(name) FROM (SELECT u.name FROM media_request_users x \
     JOIN users u ON u.id = x.user_id WHERE x.request_id = r.id ORDER BY x.created_at, x.rowid)) AS requested_by, \
     EXISTS (SELECT 1 FROM media_request_users x WHERE x.request_id = r.id AND x.user_id = ?1) AS mine \
     FROM media_requests r";

fn opt_s(value: Option<&str>) -> JsValue {
    value.map_or(JsValue::NULL, s)
}

/// What a request is for, besides its title: `""` for a movie or a whole show, `"season:episode"` for one
/// episode. Requests are unique by kind, title and slot.
pub fn request_slot(season: Option<u32>, episode: Option<u32>) -> String {
    match (season, episode) {
        (Some(s), Some(e)) => format!("{s}:{e}"),
        _ => String::new(),
    }
}

/// A title to ask for, and the episodes of it (none: the movie or the whole show).
pub struct TitleAsk<'a> {
    pub kind: &'a str,
    pub title_id: &'a str,
    pub name: &'a str,
    pub year: Option<&'a str>,
    pub poster: Option<&'a str>,
    /// (season, episode, episode name).
    pub episodes: Vec<(u32, u32, Option<&'a str>)>,
}

impl TitleAsk<'_> {
    pub fn slots(&self) -> Vec<String> {
        if self.episodes.is_empty() {
            return vec![String::new()];
        }
        self.episodes.iter().map(|(s, e, _)| request_slot(Some(*s), Some(*e))).collect()
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct UsagePoint {
    pub user_id: String,
    pub at: i64,
    pub total_bytes: f64,
}

impl Store {
    pub fn from_env(env: &Env) -> Result<Self> {
        let secret = env
            .secret("HUB_SECRET")
            .map_err(|_| worker::Error::RustError("The HUB_SECRET secret isn't set".into()))?
            .to_string();
        Ok(Self { db: env.d1("DB")?, sealer: Sealer::new(&secret) })
    }

    async fn all<T: DeserializeOwned>(&self, sql: &str, args: &[JsValue]) -> Result<Vec<T>> {
        self.db.prepare(sql).bind(args)?.all().await?.results::<T>()
    }

    async fn first<T: DeserializeOwned>(&self, sql: &str, args: &[JsValue]) -> Result<Option<T>> {
        self.db.prepare(sql).bind(args)?.first::<T>(None).await
    }

    async fn run(&self, sql: &str, args: &[JsValue]) -> Result<()> {
        self.db.prepare(sql).bind(args)?.run().await?;
        Ok(())
    }

    // -------------------------------------------------------------------------
    // Settings

    pub async fn setting(&self, key: &str) -> Result<Option<String>> {
        #[derive(Deserialize)]
        struct Row {
            value: String,
        }
        let row: Option<Row> = self.first("SELECT value FROM settings WHERE key = ?1", &[s(key)]).await?;
        Ok(row.and_then(|r| {
            if !SECRET_KEYS.contains(&key) {
                Some(r.value)
            } else {
                self.sealer.open(&r.value).or_else(|| ONCE_PLAINTEXT.contains(&key).then_some(r.value))
            }
        }))
    }

    pub async fn set_setting(&self, key: &str, value: Option<&str>) -> Result<()> {
        match value {
            None => self.run("DELETE FROM settings WHERE key = ?1", &[s(key)]).await,
            Some(value) => {
                let stored = if SECRET_KEYS.contains(&key) { self.sealer.seal(value) } else { value.to_string() };
                self.run(
                    "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    &[s(key), s(&stored)],
                )
                .await
            }
        }
    }

    // -------------------------------------------------------------------------
    // Admin sessions and login throttling

    pub async fn create_admin_session(&self, token: &str, ttl_secs: i64, mfa_ok: bool) -> Result<()> {
        let now = now();
        self.run(
            "INSERT INTO admin_sessions (token_hash, created_at, expires_at, mfa_ok) VALUES (?1, ?2, ?3, ?4)",
            &[s(&sha256_hex(token)), n(now as f64), n((now + ttl_secs) as f64), n(if mfa_ok { 1.0 } else { 0.0 })],
        )
        .await
    }

    /// Some(true) for a full session, Some(false) for one that signed in with
    /// the password but still has to set up two-factor codes.
    pub async fn admin_session(&self, token: &str) -> Result<Option<bool>> {
        #[derive(Deserialize)]
        struct Row {
            mfa_ok: i64,
        }
        let row: Option<Row> = self
            .first(
                "SELECT mfa_ok FROM admin_sessions WHERE token_hash = ?1 AND expires_at > ?2",
                &[s(&sha256_hex(token)), n(now() as f64)],
            )
            .await?;
        Ok(row.map(|r| r.mfa_ok != 0))
    }

    pub async fn mark_admin_session_mfa_ok(&self, token: &str) -> Result<()> {
        self.run("UPDATE admin_sessions SET mfa_ok = 1 WHERE token_hash = ?1", &[s(&sha256_hex(token))]).await
    }

    /// Signs out every admin session (after two-factor setup changes).
    pub async fn delete_all_admin_sessions_except(&self, token: &str) -> Result<()> {
        self.run("DELETE FROM admin_sessions WHERE token_hash != ?1", &[s(&sha256_hex(token))]).await
    }

    pub async fn delete_admin_session(&self, token: &str) -> Result<()> {
        self.run("DELETE FROM admin_sessions WHERE token_hash = ?1", &[s(&sha256_hex(token))]).await
    }

    pub async fn recent_failed_logins(&self, ip: &str, window_secs: i64) -> Result<i64> {
        #[derive(Deserialize)]
        struct Row {
            count: i64,
        }
        let row: Option<Row> = self
            .first(
                "SELECT COUNT(*) AS count FROM login_attempts WHERE ip = ?1 AND at > ?2",
                &[s(ip), n((now() - window_secs) as f64)],
            )
            .await?;
        Ok(row.map_or(0, |r| r.count))
    }

    pub async fn record_failed_login(&self, ip: &str) -> Result<()> {
        self.run("INSERT INTO login_attempts (ip, at) VALUES (?1, ?2)", &[s(ip), n(now() as f64)]).await
    }

    // -------------------------------------------------------------------------
    // Users

    pub async fn users(&self) -> Result<Vec<User>> {
        self.all("SELECT u.*, ph.version AS photo_version FROM users u LEFT JOIN photos ph ON ph.user_id = u.id ORDER BY u.created_at DESC", &[]).await
    }

    pub async fn user(&self, id: &str) -> Result<Option<User>> {
        self.first("SELECT u.*, ph.version AS photo_version FROM users u LEFT JOIN photos ph ON ph.user_id = u.id WHERE u.id = ?1", &[s(id)]).await
    }

    pub async fn create_user(
        &self,
        name: &str,
        username: &str,
        password_hash: &str,
        daily_gb: f64,
        monthly_gb: f64,
    ) -> Result<String> {
        let id = random_id();
        self.run(
            "INSERT INTO users (id, name, username, password_hash, daily_limit_gb, monthly_limit_gb, disabled, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)",
            &[s(&id), s(name), s(username), s(password_hash), n(daily_gb), n(monthly_gb), n(now() as f64)],
        )
        .await?;
        Ok(id)
    }

    pub async fn user_by_username(&self, username: &str) -> Result<Option<User>> {
        self.first("SELECT u.*, ph.version AS photo_version FROM users u LEFT JOIN photos ph ON ph.user_id = u.id WHERE u.username = ?1", &[s(username)]).await
    }

    pub async fn set_user_password(&self, id: &str, password_hash: &str) -> Result<()> {
        self.run("UPDATE users SET password_hash = ?2 WHERE id = ?1", &[s(id), s(password_hash)]).await
    }

    /// Signs the user out everywhere, or everywhere but [keep].
    pub async fn delete_devices(&self, user_id: &str, keep: Option<&str>) -> Result<()> {
        self.run("DELETE FROM devices WHERE user_id = ?1 AND id != ?2", &[s(user_id), s(keep.unwrap_or(""))]).await
    }

    /// Stores (or clears) the user's Telegram-Stremio token.
    pub async fn set_user_tgs_token(&self, id: &str, token: Option<&str>) -> Result<()> {
        let (enc, hash) = match token {
            Some(t) => (s(&self.sealer.seal(t)), s(&sha256_hex(t))),
            None => (JsValue::NULL, JsValue::NULL),
        };
        self.run("UPDATE users SET tgs_token_enc = ?2, tgs_token_hash = ?3 WHERE id = ?1", &[s(id), enc, hash]).await
    }

    pub fn user_tgs_token(&self, user: &User) -> Option<String> {
        user.tgs_token_enc.as_deref().and_then(|t| self.sealer.open(t))
    }

    pub async fn update_user(
        &self,
        id: &str,
        name: &str,
        username: &str,
        daily_gb: f64,
        monthly_gb: f64,
    ) -> Result<()> {
        self.run(
            "UPDATE users SET name = ?2, username = ?3, daily_limit_gb = ?4, monthly_limit_gb = ?5 WHERE id = ?1",
            &[s(id), s(name), s(username), n(daily_gb), n(monthly_gb)],
        )
        .await
    }

    pub async fn set_chat_admin(&self, id: &str, admin: bool) -> Result<()> {
        self.run("UPDATE users SET chat_admin = ?2 WHERE id = ?1", &[s(id), n(if admin { 1.0 } else { 0.0 })]).await
    }

    /// Mutes [id] in chat until [until] (Unix seconds), or lifts it.
    pub async fn set_chat_muted(&self, id: &str, until: Option<i64>) -> Result<()> {
        let until = until.map(|u| n(u as f64)).unwrap_or(JsValue::NULL);
        self.run("UPDATE users SET chat_muted_until = ?2 WHERE id = ?1", &[s(id), until]).await
    }

    pub async fn set_user_disabled(&self, id: &str, disabled: bool) -> Result<()> {
        self.run("UPDATE users SET disabled = ?2 WHERE id = ?1", &[s(id), n(if disabled { 1.0 } else { 0.0 })]).await
    }

    pub async fn delete_user(&self, id: &str) -> Result<()> {
        self.db
            .batch(vec![
                self.db.prepare("DELETE FROM devices WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM usage_snapshots WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM tracker_links WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM tracker_pending WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM presence WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM photos WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM join_requests WHERE from_user = ?1 OR to_user = ?1").bind(&[s(id)])?,
                self.db
                    .prepare("DELETE FROM chat_messages WHERE channel != 'public' AND (sender = ?1 OR recipient = ?1)")
                    .bind(&[s(id)])?,
                self.db.prepare("DELETE FROM chat_reads WHERE user_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM media_request_users WHERE user_id = ?1").bind(&[s(id)])?,
                self.db
                    .prepare(
                        "DELETE FROM media_requests WHERE status = 'pending' AND NOT EXISTS \
                         (SELECT 1 FROM media_request_users x WHERE x.request_id = media_requests.id)",
                    )
                    .bind(&[])?,
                self.db.prepare("DELETE FROM users WHERE id = ?1").bind(&[s(id)])?,
            ])
            .await?;
        Ok(())
    }

    // -------------------------------------------------------------------------
    // Devices

    pub async fn create_device(&self, user_id: &str, name: &str, token: &str) -> Result<String> {
        let id = random_id();
        let now = now();
        self.run(
            "INSERT INTO devices (id, token_hash, user_id, name, created_at, last_seen) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            &[s(&id), s(&sha256_hex(token)), s(user_id), s(name), n(now as f64)],
        )
        .await?;
        Ok(id)
    }

    /// The device a bearer token belongs to. Marks it seen at most hourly, to
    /// stay well inside the free plan's daily write allowance.
    pub async fn device_for_token(&self, token: &str) -> Result<Option<Device>> {
        let device: Option<Device> = self
            .first(
                "SELECT id, user_id, name, created_at, last_seen FROM devices WHERE token_hash = ?1",
                &[s(&sha256_hex(token))],
            )
            .await?;
        if let Some(d) = &device {
            if now() - d.last_seen > 3600 {
                self.run("UPDATE devices SET last_seen = ?2 WHERE id = ?1", &[s(&d.id), n(now() as f64)]).await?;
            }
        }
        Ok(device)
    }

    pub async fn devices(&self, user_id: &str) -> Result<Vec<Device>> {
        self.all(
            "SELECT id, user_id, name, created_at, last_seen FROM devices WHERE user_id = ?1 ORDER BY last_seen DESC",
            &[s(user_id)],
        )
        .await
    }

    pub async fn delete_device(&self, user_id: &str, device_id: &str) -> Result<()> {
        self.db
            .batch(vec![
                self.db
                    .prepare("DELETE FROM devices WHERE id = ?1 AND user_id = ?2")
                    .bind(&[s(device_id), s(user_id)])?,
                self.db
                    .prepare("DELETE FROM presence WHERE device_id = ?1 AND user_id = ?2")
                    .bind(&[s(device_id), s(user_id)])?,
            ])
            .await?;
        Ok(())
    }

    pub async fn active_device_count(&self, since: i64) -> Result<i64> {
        #[derive(Deserialize)]
        struct Row {
            count: i64,
        }
        let row: Option<Row> =
            self.first("SELECT COUNT(*) AS count FROM devices WHERE last_seen > ?1", &[n(since as f64)]).await?;
        Ok(row.map_or(0, |r| r.count))
    }

    // -------------------------------------------------------------------------
    // Usage history

    pub async fn record_usage(&self, points: &[(String, f64)], at: i64) -> Result<()> {
        if points.is_empty() {
            return Ok(());
        }
        let mut statements = Vec::with_capacity(points.len());
        for (user_id, bytes) in points {
            statements.push(
                self.db
                    .prepare("INSERT OR REPLACE INTO usage_snapshots (user_id, at, total_bytes) VALUES (?1, ?2, ?3)")
                    .bind(&[s(user_id), n(at as f64), n(*bytes)])?,
            );
        }
        self.db.batch(statements).await?;
        Ok(())
    }

    pub async fn usage_since(&self, since: i64) -> Result<Vec<UsagePoint>> {
        self.all("SELECT user_id, at, total_bytes FROM usage_snapshots WHERE at >= ?1 ORDER BY at", &[n(since as f64)])
            .await
    }

    // -------------------------------------------------------------------------
    // Trackers

    pub async fn tracker_links(&self, user_id: &str) -> Result<Vec<TrackerLink>> {
        #[derive(Deserialize)]
        struct Row {
            service: String,
            access_token_enc: String,
            refresh_token_enc: Option<String>,
            expires_at: Option<i64>,
            username: Option<String>,
        }
        let rows: Vec<Row> = self
            .all(
                "SELECT service, access_token_enc, refresh_token_enc, expires_at, username FROM tracker_links WHERE user_id = ?1",
                &[s(user_id)],
            )
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                Some(TrackerLink {
                    access_token: self.sealer.open(&r.access_token_enc)?,
                    refresh_token: r.refresh_token_enc.as_deref().and_then(|t| self.sealer.open(t)),
                    service: r.service,
                    expires_at: r.expires_at,
                    username: r.username,
                })
            })
            .collect())
    }

    pub async fn save_tracker_link(&self, user_id: &str, link: &TrackerLink) -> Result<()> {
        let refresh = link.refresh_token.as_deref().map(|t| self.sealer.seal(t));
        self.run(
            "INSERT OR REPLACE INTO tracker_links (user_id, service, access_token_enc, refresh_token_enc, expires_at, username, created_at)              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            &[
                s(user_id),
                s(&link.service),
                s(&self.sealer.seal(&link.access_token)),
                refresh.as_deref().map_or(JsValue::NULL, s),
                link.expires_at.map_or(JsValue::NULL, |e| n(e as f64)),
                link.username.as_deref().map_or(JsValue::NULL, s),
                n(now() as f64),
            ],
        )
        .await
    }

    pub async fn delete_tracker_link(&self, user_id: &str, service: &str) -> Result<()> {
        self.run("DELETE FROM tracker_links WHERE user_id = ?1 AND service = ?2", &[s(user_id), s(service)]).await
    }

    pub async fn set_tracker_pending(
        &self,
        user_id: &str,
        service: &str,
        device_code: &str,
        user_code: &str,
        expires_at: i64,
    ) -> Result<()> {
        self.run(
            "INSERT OR REPLACE INTO tracker_pending (user_id, service, device_code_enc, user_code, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            &[s(user_id), s(service), s(&self.sealer.seal(device_code)), s(user_code), n(expires_at as f64)],
        )
        .await
    }

    /// The device code and user code of a link in progress, unless expired.
    pub async fn tracker_pending(&self, user_id: &str, service: &str) -> Result<Option<(String, String)>> {
        #[derive(Deserialize)]
        struct Row {
            device_code_enc: String,
            user_code: String,
        }
        let row: Option<Row> = self
            .first(
                "SELECT device_code_enc, user_code FROM tracker_pending WHERE user_id = ?1 AND service = ?2 AND expires_at > ?3",
                &[s(user_id), s(service), n(now() as f64)],
            )
            .await?;
        Ok(row.and_then(|r| Some((self.sealer.open(&r.device_code_enc)?, r.user_code))))
    }

    pub async fn clear_tracker_pending(&self, user_id: &str, service: &str) -> Result<()> {
        self.run("DELETE FROM tracker_pending WHERE user_id = ?1 AND service = ?2", &[s(user_id), s(service)]).await
    }

    /// Drops expired sessions and throttling rows, and old history.
    // -------------------------------------------------------------------------
    // Profile pictures

    /// The picture's type and base64 bytes.
    pub async fn photo(&self, user_id: &str) -> Result<Option<(String, String)>> {
        #[derive(Deserialize)]
        struct Row {
            mime: String,
            data: String,
        }
        let row: Option<Row> = self.first("SELECT mime, data FROM photos WHERE user_id = ?1", &[s(user_id)]).await?;
        Ok(row.map(|r| (r.mime, r.data)))
    }

    /// Saves a picture and returns its version.
    pub async fn set_photo(&self, user_id: &str, mime: &str, data_b64: &str) -> Result<i64> {
        let version = now();
        self.run(
            "INSERT INTO photos (user_id, mime, data, version) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(user_id) DO UPDATE \
             SET mime = excluded.mime, data = excluded.data, version = MAX(excluded.version, photos.version + 1)",
            &[s(user_id), s(mime), s(data_b64), n(version as f64)],
        )
        .await?;
        Ok(version)
    }

    pub async fn delete_photo(&self, user_id: &str) -> Result<()> {
        self.run("DELETE FROM photos WHERE user_id = ?1", &[s(user_id)]).await
    }

    // -------------------------------------------------------------------------
    // File tracks

    /// The tracks JSON saved for a file, by the hash of its key.
    pub async fn file_tracks(&self, key_hash: &str) -> Result<Option<String>> {
        #[derive(Deserialize)]
        struct Row {
            tracks: String,
        }
        let row: Option<Row> = self.first("SELECT tracks FROM file_tracks WHERE key_hash = ?1", &[s(key_hash)]).await?;
        Ok(row.map(|r| r.tracks))
    }

    pub async fn set_file_tracks(&self, key_hash: &str, tracks_json: &str) -> Result<()> {
        self.run(
            "INSERT INTO file_tracks (key_hash, tracks, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT(key_hash) DO UPDATE \
             SET tracks = excluded.tracks, updated_at = excluded.updated_at",
            &[s(key_hash), s(tracks_json), n(now() as f64)],
        )
        .await
    }

    // -------------------------------------------------------------------------
    // Add-ons

    fn open_addon(&self, r: AddonDbRow) -> Option<AddonRow> {
        Some(AddonRow {
            manifest_url: self.sealer.open(&r.url_enc)?,
            id: r.id,
            name: r.name,
            position: r.position,
            enabled: r.enabled != 0,
            manifest: r.manifest,
            report: r.report,
            checked_at: r.checked_at,
        })
    }

    /// Every add-on, in the order the app uses them. One whose URL can't be
    /// opened (HUB_SECRET changed) is left out.
    pub async fn addons(&self) -> Result<Vec<AddonRow>> {
        let rows: Vec<AddonDbRow> = self.all("SELECT * FROM addons ORDER BY position, created_at", &[]).await?;
        Ok(rows.into_iter().filter_map(|r| self.open_addon(r)).collect())
    }

    pub async fn addon(&self, id: &str) -> Result<Option<AddonRow>> {
        let row: Option<AddonDbRow> = self.first("SELECT * FROM addons WHERE id = ?1", &[s(id)]).await?;
        Ok(row.and_then(|r| self.open_addon(r)))
    }

    pub async fn addon_exists(&self, manifest_url: &str) -> Result<bool> {
        let row: Option<AddonIdRow> =
            self.first("SELECT id FROM addons WHERE url_hash = ?1", &[s(&sha256_hex(manifest_url))]).await?;
        Ok(row.is_some())
    }

    /// Adds an add-on at the end of the list.
    pub async fn add_addon(
        &self,
        manifest_url: &str,
        name: &str,
        manifest: &str,
        report: &str,
        enabled: bool,
    ) -> Result<String> {
        let id = random_id();
        let now = now();
        self.run(
            "INSERT INTO addons (id, url_enc, url_hash, name, position, enabled, manifest, report, checked_at, created_at) \
             VALUES (?1, ?2, ?3, ?4, (SELECT COALESCE(MAX(position), 0) + 1 FROM addons), ?5, ?6, ?7, ?8, ?8)",
            &[
                s(&id),
                s(&self.sealer.seal(manifest_url)),
                s(&sha256_hex(manifest_url)),
                s(name),
                n(if enabled { 1.0 } else { 0.0 }),
                s(manifest),
                s(report),
                n(now as f64),
            ],
        )
        .await?;
        Ok(id)
    }

    /// Saves a new check (and the manifest it read).
    pub async fn save_addon_check(&self, id: &str, name: &str, manifest: &str, report: &str) -> Result<()> {
        self.run(
            "UPDATE addons SET name = ?2, manifest = ?3, report = ?4, checked_at = ?5 WHERE id = ?1",
            &[s(id), s(name), s(manifest), s(report), n(now() as f64)],
        )
        .await
    }

    pub async fn set_addon_enabled(&self, id: &str, enabled: bool) -> Result<()> {
        self.run("UPDATE addons SET enabled = ?2 WHERE id = ?1", &[s(id), n(if enabled { 1.0 } else { 0.0 })]).await
    }

    /// Swaps the add-on with its neighbour above ([up]) or below.
    pub async fn move_addon(&self, id: &str, up: bool) -> Result<()> {
        let list = self.addons().await?;
        let Some(i) = list.iter().position(|a| a.id == id) else { return Ok(()) };
        let Some(j) = (if up { i.checked_sub(1) } else { Some(i + 1).filter(|&j| j < list.len()) }) else {
            return Ok(());
        };
        // Positions may tie or have gaps; renumber the whole list in the new order.
        let mut order: Vec<&AddonRow> = list.iter().collect();
        order.swap(i, j);
        let statements = order
            .iter()
            .enumerate()
            .map(|(p, a)| {
                self.db.prepare("UPDATE addons SET position = ?2 WHERE id = ?1").bind(&[s(&a.id), n((p + 1) as f64)])
            })
            .collect::<Result<Vec<_>>>()?;
        self.db.batch(statements).await?;
        Ok(())
    }

    pub async fn delete_addon(&self, id: &str) -> Result<()> {
        self.run("DELETE FROM addons WHERE id = ?1", &[s(id)]).await
    }

    // -------------------------------------------------------------------------
    // Presence and join requests

    /// Every device's presence, for users who aren't turned off.
    pub async fn presence_rows(&self) -> Result<Vec<PresenceRow>> {
        self.all(
            "SELECT p.device_id, p.user_id, u.name, p.seen_at, p.watching, p.watching_since, p.ip, \
             d.name AS device_name, ph.version AS photo_version, u.chat_admin FROM presence p JOIN users u ON u.id = p.user_id \
             LEFT JOIN devices d ON d.id = p.device_id \
             LEFT JOIN photos ph ON ph.user_id = p.user_id WHERE u.disabled = 0",
            &[],
        )
        .await
    }

    pub async fn save_presence(
        &self,
        user_id: &str,
        device_id: &str,
        seen_at: i64,
        watching: Option<&str>,
        since: Option<i64>,
        ip: &str,
    ) -> Result<()> {
        self.run(
            "INSERT INTO presence (device_id, user_id, seen_at, watching, watching_since, ip) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT(device_id) DO UPDATE SET user_id = excluded.user_id, seen_at = excluded.seen_at, \
             watching = excluded.watching, watching_since = excluded.watching_since, ip = excluded.ip",
            &[
                s(device_id),
                s(user_id),
                n(seen_at as f64),
                opt_s(watching),
                since.map_or(JsValue::NULL, |v| n(v as f64)),
                s(ip),
            ],
        )
        .await
    }

    /// Requests to or from [user_id] made since [since].
    pub async fn join_requests_for(&self, user_id: &str, since: i64) -> Result<Vec<JoinRow>> {
        self.all(
            &format!(
                "{JOIN_SELECT} WHERE (r.from_user = ?1 OR r.to_user = ?1) AND (r.created_at >= ?2 OR r.answered_at >= ?2) \
                 ORDER BY r.created_at DESC LIMIT 50"
            ),
            &[s(user_id), n(since as f64)],
        )
        .await
    }

    pub async fn join_request(&self, id: &str) -> Result<Option<JoinRow>> {
        self.first(&format!("{JOIN_SELECT} WHERE r.id = ?1"), &[s(id)]).await
    }

    /// A new pending request, replacing any earlier one between the two.
    pub async fn create_join_request(&self, from: &str, to: &str, title: &str) -> Result<String> {
        let id = random_id();
        self.db
            .batch(vec![
                self.db
                    .prepare("DELETE FROM join_requests WHERE from_user = ?1 AND to_user = ?2")
                    .bind(&[s(from), s(to)])?,
                self.db
                    .prepare(
                        "INSERT INTO join_requests (id, from_user, to_user, title, status, created_at) \
                         VALUES (?1, ?2, ?3, ?4, 'pending', ?5)",
                    )
                    .bind(&[s(&id), s(from), s(to), s(title), n(now() as f64)])?,
            ])
            .await?;
        Ok(id)
    }

    pub async fn answer_join_request(&self, id: &str, status: &str, room: Option<&str>) -> Result<()> {
        self.run(
            "UPDATE join_requests SET status = ?2, room = ?3, answered_at = ?4 WHERE id = ?1 AND status = 'pending'",
            &[s(id), s(status), opt_s(room), n(now() as f64)],
        )
        .await
    }

    /// Deletes a request [user_id] sent or received.
    pub async fn delete_join_request(&self, id: &str, user_id: &str) -> Result<()> {
        self.run("DELETE FROM join_requests WHERE id = ?1 AND (from_user = ?2 OR to_user = ?2)", &[s(id), s(user_id)])
            .await
    }

    // -------------------------------------------------------------------------
    // Chat

    /// Saves a message and returns it with its id.
    pub async fn add_chat(&self, channel: &str, sender: &str, recipient: Option<&str>, text: &str) -> Result<ChatRow> {
        let row: Option<IdRow> = self
            .first(
                "INSERT INTO chat_messages (channel, sender, recipient, text, sent_at) VALUES (?1, ?2, ?3, ?4, ?5) \
                 RETURNING id",
                &[s(channel), s(sender), recipient.map(s).unwrap_or(JsValue::NULL), s(text), n(now() as f64)],
            )
            .await?;
        let id = row.ok_or_else(|| worker::Error::RustError("the message wasn't saved".into()))?.id;
        self.first(&format!("{CHAT_SELECT} WHERE m.id = ?1"), &[n(id as f64)])
            .await?
            .ok_or_else(|| worker::Error::RustError("the message wasn't saved".into()))
    }

    pub async fn chat_message(&self, id: i64) -> Result<Option<ChatRow>> {
        self.first(&format!("{CHAT_SELECT} WHERE m.id = ?1"), &[n(id as f64)]).await
    }

    /// Deletes message [id] for good.
    pub async fn delete_chat(&self, id: i64) -> Result<()> {
        self.run("DELETE FROM chat_messages WHERE id = ?1", &[n(id as f64)]).await
    }

    /// How many messages [sender] sent since [since] (Unix seconds).
    pub async fn chat_sent_since(&self, sender: &str, since: i64) -> Result<i64> {
        #[derive(Deserialize)]
        struct Count {
            n: i64,
        }
        let row: Option<Count> = self
            .first(
                "SELECT COUNT(*) AS n FROM chat_messages WHERE sender = ?1 AND sent_at >= ?2",
                &[s(sender), n(since as f64)],
            )
            .await?;
        Ok(row.map_or(0, |r| r.n))
    }

    /// Up to [limit] messages of [channel], oldest first: the latest, those
    /// before [before], or those after [after]. Asks for one more than
    /// [limit], so a longer answer means there are more.
    pub async fn chat_page(
        &self,
        channel: &str,
        before: Option<i64>,
        after: Option<i64>,
        limit: u32,
    ) -> Result<Vec<ChatRow>> {
        let take = n((limit + 1) as f64);
        let rows: Vec<ChatRow> = match (before, after) {
            (_, Some(after)) => {
                self.all(
                    &format!("{CHAT_SELECT} WHERE m.channel = ?1 AND m.id > ?2 ORDER BY m.id ASC LIMIT ?3"),
                    &[s(channel), n(after as f64), take],
                )
                .await?
            }
            (Some(before), None) => {
                let mut rows: Vec<ChatRow> = self
                    .all(
                        &format!("{CHAT_SELECT} WHERE m.channel = ?1 AND m.id < ?2 ORDER BY m.id DESC LIMIT ?3"),
                        &[s(channel), n(before as f64), take],
                    )
                    .await?;
                rows.reverse();
                rows
            }
            (None, None) => {
                let mut rows: Vec<ChatRow> = self
                    .all(
                        &format!("{CHAT_SELECT} WHERE m.channel = ?1 ORDER BY m.id DESC LIMIT ?2"),
                        &[s(channel), take],
                    )
                    .await?;
                rows.reverse();
                rows
            }
        };
        Ok(rows)
    }

    /// The public channel's latest message (if any), then [user_id]'s private
    /// chats, latest first.
    pub async fn chat_channels(&self, user_id: &str) -> Result<(Option<ChatChannelRow>, Vec<ChatChannelRow>)> {
        let public = self
            .first(
                &format!(
                    "SELECT x.*, {CHAT_UNREAD} FROM ({CHAT_SELECT} WHERE m.channel = 'public' \
                     ORDER BY m.id DESC LIMIT 1) x JOIN chat_messages m ON m.id = x.id"
                ),
                &[s(user_id)],
            )
            .await?;
        let direct = self
            .all(
                &format!(
                    "SELECT x.*, uo.id AS other_id, uo.name AS other_name, po.version AS other_photo, \
                     uo.chat_admin AS other_admin, {CHAT_UNREAD} \
                     FROM ({CHAT_SELECT} WHERE m.id IN (SELECT MAX(id) FROM chat_messages WHERE channel != 'public' \
                     AND (sender = ?1 OR recipient = ?1) GROUP BY channel)) x JOIN chat_messages m ON m.id = x.id \
                     JOIN users uo ON uo.id = CASE WHEN m.sender = ?1 THEN m.recipient ELSE m.sender END \
                     LEFT JOIN photos po ON po.user_id = uo.id ORDER BY x.id DESC LIMIT 200"
                ),
                &[s(user_id)],
            )
            .await?;
        Ok((public, direct))
    }

    /// Moves [user_id]'s read marker in [channel] forward to [up_to].
    pub async fn mark_chat_read(&self, user_id: &str, channel: &str, up_to: i64) -> Result<()> {
        self.run(
            "INSERT INTO chat_reads (user_id, channel, last_read) VALUES (?1, ?2, ?3) \
             ON CONFLICT(user_id, channel) DO UPDATE SET last_read = MAX(last_read, excluded.last_read)",
            &[s(user_id), s(channel), n(up_to as f64)],
        )
        .await
    }

    // -------------------------------------------------------------------------
    // Title requests

    /// Requests as [user_id] sees them, most recently changed first; [statuses] narrows them (empty: all).
    pub async fn media_requests(&self, user_id: &str, statuses: &[&str]) -> Result<Vec<MediaRequestRow>> {
        let mut args = vec![s(user_id)];
        let filter = if statuses.is_empty() {
            String::new()
        } else {
            let marks: Vec<String> = (0..statuses.len()).map(|i| format!("?{}", i + 2)).collect();
            args.extend(statuses.iter().map(|st| s(st)));
            format!(" WHERE r.status IN ({})", marks.join(", "))
        };
        self.all(
            &format!("{REQUEST_SELECT}{filter} ORDER BY r.updated_at DESC, r.title_id, r.season, r.episode LIMIT 1000"),
            &args,
        )
        .await
    }

    /// The requests for these [slots] of a title, as [user_id] sees them, in episode order.
    pub async fn media_requests_for_slots(
        &self,
        user_id: &str,
        kind: &str,
        title_id: &str,
        slots: &[String],
    ) -> Result<Vec<MediaRequestRow>> {
        if slots.is_empty() {
            return Ok(vec![]);
        }
        let marks: Vec<String> = (0..slots.len()).map(|i| format!("?{}", i + 4)).collect();
        let mut args = vec![s(user_id), s(kind), s(title_id)];
        args.extend(slots.iter().map(|x| s(x)));
        self.all(
            &format!(
                "{REQUEST_SELECT} WHERE r.kind = ?2 AND r.title_id = ?3 AND r.slot IN ({}) ORDER BY r.season, r.episode",
                marks.join(", ")
            ),
            &args,
        )
        .await
    }

    pub async fn media_request(&self, id: &str, user_id: &str) -> Result<Option<MediaRequestRow>> {
        self.first(&format!("{REQUEST_SELECT} WHERE r.id = ?2"), &[s(user_id), s(id)]).await
    }

    /// How many requests are waiting for the admin.
    pub async fn pending_request_count(&self) -> Result<i64> {
        #[derive(Deserialize)]
        struct Row {
            count: i64,
        }
        let row: Option<Row> =
            self.first("SELECT COUNT(*) AS count FROM media_requests WHERE status = 'pending'", &[]).await?;
        Ok(row.map_or(0, |r| r.count))
    }

    /// How many requests [user_id] is waiting on (pending or approved).
    pub async fn open_requests_of(&self, user_id: &str) -> Result<i64> {
        #[derive(Deserialize)]
        struct Row {
            count: i64,
        }
        let row: Option<Row> = self
            .first(
                "SELECT COUNT(*) AS count FROM media_request_users x JOIN media_requests r ON r.id = x.request_id \
                 WHERE x.user_id = ?1 AND r.status IN ('pending', 'approved')",
                &[s(user_id)],
            )
            .await?;
        Ok(row.map_or(0, |r| r.count))
    }

    /// Asks for a title, or some of its episodes, for [user_id]: a new pending request for each, or their name
    /// added to the one there is. A declined one asked for again goes back to pending without the old note.
    /// Returns the requests asked for, in episode order.
    pub async fn ask_for(&self, user_id: &str, ask: &TitleAsk<'_>) -> Result<Vec<MediaRequestRow>> {
        let at = n(now() as f64);
        let slots = ask.slots();
        let mut statements = Vec::with_capacity(slots.len() * 2);
        let whole = [(0, 0, None)];
        let parts: &[(u32, u32, Option<&str>)] = if ask.episodes.is_empty() { &whole } else { &ask.episodes };
        for ((season, episode, title), slot) in parts.iter().zip(&slots) {
            let (season, episode) =
                if slot.is_empty() { (JsValue::NULL, JsValue::NULL) } else { (n(*season as f64), n(*episode as f64)) };
            statements.push(
                self.db
                    .prepare(
                        "INSERT INTO media_requests (id, kind, title_id, name, year, poster, season, episode, \
                         episode_title, slot, status, created_at, updated_at) \
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pending', ?11, ?11) \
                         ON CONFLICT(kind, title_id, slot) DO UPDATE SET \
                         status = CASE WHEN status = 'declined' THEN 'pending' ELSE status END, \
                         note = CASE WHEN status = 'declined' THEN NULL ELSE note END, \
                         updated_at = CASE WHEN status = 'declined' THEN excluded.updated_at ELSE updated_at END, \
                         year = COALESCE(year, excluded.year), poster = COALESCE(poster, excluded.poster), \
                         episode_title = COALESCE(episode_title, excluded.episode_title)",
                    )
                    .bind(&[
                        s(&random_id()),
                        s(ask.kind),
                        s(ask.title_id),
                        s(ask.name),
                        opt_s(ask.year),
                        opt_s(ask.poster),
                        season,
                        episode,
                        opt_s(*title),
                        s(slot),
                        at.clone(),
                    ])?,
            );
            statements.push(
                self.db
                    .prepare(
                        "INSERT OR IGNORE INTO media_request_users (request_id, user_id, created_at) \
                         SELECT id, ?1, ?2 FROM media_requests WHERE kind = ?3 AND title_id = ?4 AND slot = ?5",
                    )
                    .bind(&[s(user_id), at.clone(), s(ask.kind), s(ask.title_id), s(slot)])?,
            );
        }
        self.db.batch(statements).await?;
        self.media_requests_for_slots(user_id, ask.kind, ask.title_id, &slots).await
    }

    /// Takes [user_id] off a request; a pending one nobody wants any more goes.
    pub async fn withdraw_request(&self, id: &str, user_id: &str) -> Result<()> {
        self.db
            .batch(vec![
                self.db
                    .prepare("DELETE FROM media_request_users WHERE request_id = ?1 AND user_id = ?2")
                    .bind(&[s(id), s(user_id)])?,
                self.db
                    .prepare(
                        "DELETE FROM media_requests WHERE id = ?1 AND status = 'pending' AND NOT EXISTS \
                         (SELECT 1 FROM media_request_users x WHERE x.request_id = ?1)",
                    )
                    .bind(&[s(id)])?,
            ])
            .await?;
        Ok(())
    }

    /// The admin's answer: a status from `request_status::ALL` and an optional note.
    pub async fn set_request_status(&self, id: &str, status: &str, note: Option<&str>) -> Result<()> {
        self.run(
            "UPDATE media_requests SET status = ?2, note = ?3, updated_at = ?4 WHERE id = ?1",
            &[s(id), s(status), opt_s(note), n(now() as f64)],
        )
        .await
    }

    pub async fn delete_request(&self, id: &str) -> Result<()> {
        self.db
            .batch(vec![
                self.db.prepare("DELETE FROM media_request_users WHERE request_id = ?1").bind(&[s(id)])?,
                self.db.prepare("DELETE FROM media_requests WHERE id = ?1").bind(&[s(id)])?,
            ])
            .await?;
        Ok(())
    }

    /// Deletes requests answered for good (Added or Declined) that last changed before [before], and says how many.
    pub async fn delete_answered_requests(&self, before: i64) -> Result<i64> {
        #[derive(Deserialize)]
        struct Row {
            count: i64,
        }
        const ANSWERED: &str = "status IN ('added', 'declined') AND updated_at < ?1";
        let row: Option<Row> = self
            .first(&format!("SELECT COUNT(*) AS count FROM media_requests WHERE {ANSWERED}"), &[n(before as f64)])
            .await?;
        let count = row.map_or(0, |r| r.count);
        if count > 0 {
            self.db
                .batch(vec![
                    self.db
                        .prepare(&format!(
                            "DELETE FROM media_request_users WHERE request_id IN \
                             (SELECT id FROM media_requests WHERE {ANSWERED})"
                        ))
                        .bind(&[n(before as f64)])?,
                    self.db
                        .prepare(&format!("DELETE FROM media_requests WHERE {ANSWERED}"))
                        .bind(&[n(before as f64)])?,
                ])
                .await?;
        }
        Ok(count)
    }

    pub async fn cleanup(&self) -> Result<()> {
        let now = now();
        // Answered requests are kept for a while so friends see the answer, then dropped.
        self.delete_answered_requests(now - ANSWERED_REQUEST_DAYS * 86_400).await?;
        self.db
            .batch(vec![
                self.db.prepare("DELETE FROM admin_sessions WHERE expires_at < ?1").bind(&[n(now as f64)])?,
                self.db.prepare("DELETE FROM login_attempts WHERE at < ?1").bind(&[n((now - 86_400) as f64)])?,
                self.db.prepare("DELETE FROM usage_snapshots WHERE at < ?1").bind(&[n((now - 35 * 86_400) as f64)])?,
                self.db.prepare("DELETE FROM tracker_pending WHERE expires_at < ?1").bind(&[n(now as f64)])?,
                self.db.prepare("DELETE FROM presence WHERE seen_at < ?1").bind(&[n((now - 30 * 86_400) as f64)])?,
                self.db.prepare("DELETE FROM join_requests WHERE created_at < ?1").bind(&[n((now - 3600) as f64)])?,
            ])
            .await?;
        Ok(())
    }
}
