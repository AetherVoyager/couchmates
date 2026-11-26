//! Voice chat's connection choice, and direct (peer-to-peer) voice.
//!
//! The admin picks LiveKit or direct on the settings page. In direct mode
//! the apps in a room connect to each other with WebRTC and fall back to the
//! admin's TURN relay (coturn) when they can't reach each other. The Hub:
//! - hands out the relay's address with a login that expires with the grant
//!   (coturn's `use-auth-secret`), or the relay's fixed username and
//!   password, only to signed-in apps;
//! - keeps who is in each room (`voice_peers`, refreshed by each app every
//!   `VOICE_PEER_HEARTBEAT_SECS` seconds);
//! - passes offers, answers and ICE candidates between two devices as
//!   `voice` frames on the live chat socket. It never sees any audio.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
pub use couchmates_core::api::voice_mode;
use couchmates_core::api::{
    ChatEvent, IceServer, OkResponse, VoicePeer, VoicePeers, VoicePeersRequest, VoiceSignal, VoiceSignalSend,
    VoiceTokenResponse,
};
/// A peer not heard from for this long has left.
pub use couchmates_core::rules::VOICE_PEER_STALE_SECS as STALE_SECS;
use couchmates_core::rules::{VOICE_PEER_STALE_SECS, room_for_watch_code};
use hmac::{Hmac, KeyInit, Mac};
use sha1::Sha1;
use worker::{Env, Request, Response, Result};

use crate::api::authenticate;
use crate::chat::push;
use crate::livekit::LiveKitConfig;
use crate::store::{Store, now};
use crate::web::{self, json_error};

/// `livekit` or `direct`.
pub const MODE: &str = "voice_mode";
/// The relay as `host:port`.
pub const TURN_SERVER: &str = "turn_server";
/// coturn's `static-auth-secret` (sealed).
pub const TURN_SECRET: &str = "turn_secret";
/// A fixed relay login, when there's no shared secret.
pub const TURN_USERNAME: &str = "turn_username";
/// Its password (sealed).
pub const TURN_PASSWORD: &str = "turn_password";

/// Longest signal the Hub passes on (an SDP is a few KB).
const MAX_SIGNAL_BYTES: usize = 16 * 1024;
const SIGNAL_KINDS: &[&str] = &["offer", "answer", "ice", "hello"];

/// How apps sign in to the relay.
#[derive(Debug, Clone, PartialEq)]
pub enum RelayAuth {
    /// coturn `use-auth-secret`: logins made from the secret, which expire.
    Secret(String),
    /// coturn `lt-cred-mech` with a fixed user.
    Password { username: String, password: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct RelayConfig {
    /// `host:port`.
    pub server: String,
    pub auth: RelayAuth,
}

impl RelayConfig {
    pub async fn load(store: &Store) -> Result<Option<Self>> {
        let Some(server) = store.setting(TURN_SERVER).await? else {
            return Ok(None);
        };
        if let Some(secret) = store.setting(TURN_SECRET).await? {
            return Ok(Some(Self { server, auth: RelayAuth::Secret(secret) }));
        }
        match (store.setting(TURN_USERNAME).await?, store.setting(TURN_PASSWORD).await?) {
            (Some(username), Some(password)) => {
                Ok(Some(Self { server, auth: RelayAuth::Password { username, password } }))
            }
            _ => Ok(None),
        }
    }

    /// The ICE servers for [user_id], with a login valid until [expires].
    pub fn ice_servers(&self, user_id: &str, expires: i64) -> Vec<IceServer> {
        let (username, credential) = match &self.auth {
            RelayAuth::Secret(secret) => {
                let username = format!("{expires}:{user_id}");
                let credential = turn_credential(secret, &username);
                (username, credential)
            }
            RelayAuth::Password { username, password } => (username.clone(), password.clone()),
        };
        vec![
            IceServer { urls: vec![format!("stun:{}", self.server)], username: None, credential: None },
            IceServer {
                urls: vec![
                    format!("turn:{}?transport=udp", self.server),
                    format!("turn:{}?transport=tcp", self.server),
                ],
                username: Some(username),
                credential: Some(credential),
            },
        ]
    }
}

/// coturn's REST API password for [username]: base64(HMAC-SHA1(secret, username)).
pub fn turn_credential(secret: &str, username: &str) -> String {
    let mut mac = Hmac::<Sha1>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(username.as_bytes());
    STANDARD.encode(mac.finalize().into_bytes())
}

/// The relay as `host:port` from what the admin typed (`turn:host:port`,
/// `host`, `host:3478`, …). None when it doesn't look like an address.
pub fn normalize_server(input: &str) -> Option<String> {
    let mut s = input.trim();
    for prefix in ["turns:", "turn:", "stun:", "stuns:"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest;
        }
    }
    let s = s.trim_start_matches('/');
    let s = s.split(['?', '/']).next().unwrap_or_default();
    let (host, port) = match s.rsplit_once(':') {
        Some((h, p)) if !h.contains(':') || h.starts_with('[') => (h, p.parse::<u16>().ok()?),
        _ => (s, 3478),
    };
    let ok = !host.is_empty()
        && host.len() <= 253
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '[' | ']' | ':'));
    (ok && port != 0).then(|| format!("{host}:{port}"))
}

/// The mode apps get: direct only when it's picked and the relay is set up.
pub async fn mode(store: &Store) -> Result<&'static str> {
    if store.setting(MODE).await?.as_deref() == Some(voice_mode::DIRECT) && RelayConfig::load(store).await?.is_some() {
        Ok(voice_mode::DIRECT)
    } else {
        Ok(voice_mode::LIVEKIT)
    }
}

/// Whether apps can use voice chat at all.
pub async fn available(store: &Store) -> Result<bool> {
    Ok(mode(store).await? == voice_mode::DIRECT || LiveKitConfig::load(store).await?.is_some())
}

/// A direct-mode grant for [identity] in [room], valid for [ttl_secs].
pub fn direct_grant(
    relay: &RelayConfig,
    user_id: &str,
    identity: &str,
    room: &str,
    ttl_secs: i64,
) -> VoiceTokenResponse {
    VoiceTokenResponse {
        url: String::new(),
        token: String::new(),
        room: room.to_string(),
        mode: voice_mode::DIRECT.to_string(),
        ice_servers: relay.ice_servers(user_id, now() + ttl_secs),
        identity: Some(identity.to_string()),
    }
}

fn identity_of(user_id: &str, device_id: &str) -> String {
    format!("{user_id}:{device_id}")
}

fn user_of(identity: &str) -> &str {
    identity.split(':').next().unwrap_or_default()
}

async fn tell(env: &Env, to: Vec<String>, signal: VoiceSignal) {
    if to.is_empty() {
        return;
    }
    let event = ChatEvent { kind: "voice".into(), message: None, voice: Some(signal) };
    if let Err(e) = push(env, Some(to), &event).await {
        worker::console_warn!("voice push failed: {e}");
    }
}

/// `POST /api/app/voice/peers`: join, stay in, or leave a direct voice room.
pub async fn peers(mut req: Request, store: &Store, env: &Env) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<VoicePeersRequest>().await else {
        return json_error("Send {\"room\": \"<watch party room code>\"}.", 400);
    };
    let Some(room) = room_for_watch_code(&body.room) else {
        return json_error("That isn't a room code.", 400);
    };
    let identity = identity_of(&user.id, &device.id);
    let now = now();
    let previous = store.voice_peer(&identity).await?;
    let fresh = |seen: i64| seen >= now - VOICE_PEER_STALE_SECS;

    if body.leaving {
        if let Some(p) = previous.filter(|p| p.room == room) {
            store.delete_voice_peer(&identity).await?;
            let others = store.voice_peers(&p.room, now - VOICE_PEER_STALE_SECS).await?;
            let to = others.into_iter().map(|o| o.user_id).collect();
            tell(env, dedup(to), signal(&room, &identity, &user.name, "left")).await;
        }
        return web::json(&VoicePeers { identity, peers: vec![] }, 200);
    }

    // Moved rooms: the old room hears this device left.
    if let Some(p) = previous.as_ref().filter(|p| p.room != room) {
        let old = store.voice_peers(&p.room, now - VOICE_PEER_STALE_SECS).await?;
        let to = old.into_iter().filter(|o| o.identity != identity).map(|o| o.user_id).collect();
        tell(env, dedup(to), signal(&p.room, &identity, &user.name, "left")).await;
    }
    let is_new = previous.as_ref().is_none_or(|p| p.room != room || !fresh(p.seen_at));
    store.save_voice_peer(&identity, &room, &user.id, &user.name, now).await?;
    let others: Vec<_> = store
        .voice_peers(&room, now - VOICE_PEER_STALE_SECS)
        .await?
        .into_iter()
        .filter(|p| p.identity != identity)
        .collect();
    if is_new {
        let to = others.iter().map(|o| o.user_id.clone()).collect();
        tell(env, dedup(to), signal(&room, &identity, &user.name, "joined")).await;
    }
    let peers = others.into_iter().map(|p| VoicePeer { identity: p.identity, name: p.name }).collect();
    web::json(&VoicePeers { identity, peers }, 200)
}

/// `POST /api/app/voice/signal`: passes one message to another device in
/// the same direct voice room.
pub async fn send_signal(mut req: Request, store: &Store, env: &Env) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<VoiceSignalSend>().await else {
        return json_error("Send room, to, kind and data.", 400);
    };
    let Some(room) = room_for_watch_code(&body.room) else {
        return json_error("That isn't a room code.", 400);
    };
    if !SIGNAL_KINDS.contains(&body.kind.as_str()) || body.data.len() > MAX_SIGNAL_BYTES {
        return json_error("That isn't a voice message the Hub passes on.", 400);
    }
    let identity = identity_of(&user.id, &device.id);
    let since = now() - VOICE_PEER_STALE_SECS;
    let in_room =
        |p: &Option<crate::store::VoicePeerRow>| p.as_ref().is_some_and(|p| p.room == room && p.seen_at >= since);
    if !in_room(&store.voice_peer(&identity).await?) {
        return json_error("Join the voice room first.", 409);
    }
    if !in_room(&store.voice_peer(&body.to).await?) {
        return json_error("They've left the voice room.", 404);
    }
    let mut message = signal(&room, &identity, &user.name, &body.kind);
    message.to = Some(body.to.clone());
    message.data = body.data;
    tell(env, vec![user_of(&body.to).to_string()], message).await;
    web::json(&OkResponse { ok: true }, 200)
}

fn signal(room: &str, from: &str, name: &str, kind: &str) -> VoiceSignal {
    VoiceSignal {
        room: room.to_string(),
        from: from.to_string(),
        name: name.to_string(),
        to: None,
        kind: kind.to_string(),
        data: String::new(),
    }
}

fn dedup(mut users: Vec<String>) -> Vec<String> {
    users.sort();
    users.dedup();
    users
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_credentials_match_coturn() {
        // From coturn's turnutils_secure: HMAC-SHA1 of the username with the secret, base64.
        assert_eq!(turn_credential("north", "1600000000:alice"), {
            let mut mac = Hmac::<Sha1>::new_from_slice(b"north").unwrap();
            mac.update(b"1600000000:alice");
            STANDARD.encode(mac.finalize().into_bytes())
        });
        // RFC 2202 test case 2.
        assert_eq!(turn_credential("Jefe", "what do ya want for nothing?"), "7/zfauXrL6LSdBbV8YTfnCWafHk=");
    }

    #[test]
    fn relay_addresses_are_normalized() {
        assert_eq!(normalize_server("68.233.106.157").as_deref(), Some("68.233.106.157:3478"));
        assert_eq!(
            normalize_server(" turn:68.233.106.157:3478?transport=udp ").as_deref(),
            Some("68.233.106.157:3478")
        );
        assert_eq!(normalize_server("relay.example.com:5000").as_deref(), Some("relay.example.com:5000"));
        assert_eq!(normalize_server("stun://relay.example.com").as_deref(), Some("relay.example.com:3478"));
        assert_eq!(normalize_server(""), None);
        assert_eq!(normalize_server("bad host:3478"), None);
        assert_eq!(normalize_server("host:99999"), None);
    }

    #[test]
    fn ice_servers_carry_the_login() {
        let relay = RelayConfig { server: "203.0.113.5:3478".into(), auth: RelayAuth::Secret("s".into()) };
        let servers = relay.ice_servers("u1", 1_700_000_000);
        assert_eq!(servers[0].urls, ["stun:203.0.113.5:3478"]);
        assert_eq!(servers[1].urls.len(), 2);
        assert_eq!(servers[1].username.as_deref(), Some("1700000000:u1"));
        assert_eq!(servers[1].credential.as_deref(), Some(turn_credential("s", "1700000000:u1").as_str()));
        let fixed = RelayConfig {
            server: "h:1".into(),
            auth: RelayAuth::Password { username: "duo".into(), password: "pw".into() },
        };
        assert_eq!(fixed.ice_servers("u1", 0)[1].username.as_deref(), Some("duo"));
    }
}
