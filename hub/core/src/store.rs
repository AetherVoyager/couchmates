//! D1 access: settings, sessions, users, devices and usage history.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use worker::wasm_bindgen::JsValue;
use worker::{D1Database, Env, Result};

use crate::crypto::{Sealer, random_id, sha256_hex};

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
}

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

fn opt_s(value: Option<&str>) -> JsValue {
    value.map_or(JsValue::NULL, s)
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
    // Presence and join requests

    /// Every device's presence, for users who aren't turned off.
    pub async fn presence_rows(&self) -> Result<Vec<PresenceRow>> {
        self.all(
            "SELECT p.device_id, p.user_id, u.name, p.seen_at, p.watching, p.watching_since, \
             ph.version AS photo_version FROM presence p JOIN users u ON u.id = p.user_id \
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
    ) -> Result<()> {
        self.run(
            "INSERT INTO presence (device_id, user_id, seen_at, watching, watching_since) VALUES (?1, ?2, ?3, ?4, ?5) \
             ON CONFLICT(device_id) DO UPDATE SET user_id = excluded.user_id, seen_at = excluded.seen_at, \
             watching = excluded.watching, watching_since = excluded.watching_since",
            &[
                s(device_id),
                s(user_id),
                n(seen_at as f64),
                opt_s(watching),
                since.map_or(JsValue::NULL, |v| n(v as f64)),
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

    pub async fn cleanup(&self) -> Result<()> {
        let now = now();
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
