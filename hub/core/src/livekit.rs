//! LiveKit: join tokens for app users, and the server check behind the
//! dashboard's Test button. The API secret never leaves the Hub.

use serde_json::{Value, json};
use worker::{Fetch, Headers, Method, Request, RequestInit, Result};

use crate::crypto::sign_jwt;
use crate::store::{Store, now};

pub struct LiveKitConfig {
    /// `wss://...` as the app connects to it.
    pub url: String,
    pub api_key: String,
    pub api_secret: String,
}

impl LiveKitConfig {
    pub async fn load(store: &Store) -> Result<Option<Self>> {
        let (Some(url), Some(api_key), Some(api_secret)) = (
            store.setting("livekit_url").await?,
            store.setting("livekit_key").await?,
            store.setting("livekit_secret").await?,
        ) else {
            return Ok(None);
        };
        Ok(Some(Self { url, api_key, api_secret }))
    }

    /// The HTTP(S) address of the server API, from the WebSocket URL.
    pub fn api_base(&self) -> String {
        if let Some(rest) = self.url.strip_prefix("wss://") {
            format!("https://{rest}")
        } else if let Some(rest) = self.url.strip_prefix("ws://") {
            format!("http://{rest}")
        } else {
            self.url.clone()
        }
    }

    /// A token that lets [identity] talk and listen in [room].
    pub fn join_token(&self, identity: &str, name: &str, room: &str, ttl_secs: i64) -> String {
        let now = now();
        sign_jwt(
            &self.api_secret,
            &json!({
                "iss": self.api_key,
                "sub": identity,
                "name": name,
                "nbf": now - 10,
                "iat": now,
                "exp": now + ttl_secs,
                "video": {
                    "room": room,
                    "roomJoin": true,
                    "canPublish": true,
                    "canSubscribe": true,
                    "canPublishData": false,
                    "canPublishSources": ["microphone"],
                },
            }),
        )
    }

    /// A short-lived admin token; [room] for calls about one room.
    fn admin_token(&self, room: Option<&str>) -> String {
        let now = now();
        let mut video = json!({"roomList": true, "roomAdmin": true});
        if let Some(room) = room {
            video["room"] = json!(room);
        }
        sign_jwt(
            &self.api_secret,
            &json!({
                "iss": self.api_key,
                "sub": "couchmates-hub",
                "nbf": now - 10,
                "exp": now + 60,
                "video": video,
            }),
        )
    }

    /// Who is in [room] and whether each person's microphone is on, muted,
    /// or not published at all.
    pub async fn list_participants(&self, room: &str) -> std::result::Result<Vec<VoiceMember>, String> {
        let body = self.twirp("ListParticipants", &json!({ "room": room }), Some(room)).await?;
        Ok(body
            .get("participants")
            .and_then(Value::as_array)
            .map(|list| list.iter().map(voice_member).collect())
            .unwrap_or_default())
    }

    async fn twirp(&self, method: &str, body: &Value, room: Option<&str>) -> std::result::Result<Value, String> {
        let headers = Headers::new();
        let set = |k: &str, v: &str| headers.set(k, v).map_err(|e| e.to_string());
        set("content-type", "application/json")?;
        set("authorization", &format!("Bearer {}", self.admin_token(room)))?;
        let mut init = RequestInit::new();
        init.with_method(Method::Post).with_headers(headers).with_body(Some(body.to_string().into()));
        let url = format!("{}/twirp/livekit.RoomService/{method}", self.api_base());
        let request = Request::new_with_init(&url, &init).map_err(|e| e.to_string())?;
        let mut response =
            Fetch::Request(request).send().await.map_err(|e| format!("couldn't reach the server: {e}"))?;
        let status = response.status_code();
        let text = response.text().await.unwrap_or_default();
        match status {
            200..=299 => {}
            401 => return Err("the server rejected the API key or secret".into()),
            404 => return Err("that address doesn't look like a LiveKit server".into()),
            _ => {
                return Err(format!("the server answered {status}: {}", text.chars().take(160).collect::<String>()));
            }
        }
        serde_json::from_str(&text).map_err(|_| "the server's answer wasn't JSON".to_string())
    }

    /// The server's open rooms, which also proves the URL, key and secret
    /// work together.
    pub async fn list_rooms(&self) -> std::result::Result<Vec<VoiceRoom>, String> {
        let body = self.twirp("ListRooms", &json!({}), None).await?;
        Ok(rooms_from(&body))
    }
}

pub struct VoiceRoom {
    pub name: String,
    pub participants: u64,
}

fn rooms_from(body: &Value) -> Vec<VoiceRoom> {
    body.get("rooms")
        .and_then(Value::as_array)
        .map(|rooms| {
            rooms
                .iter()
                .map(|r| VoiceRoom {
                    name: r.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
                    participants: r
                        .get("num_participants")
                        .or_else(|| r.get("numParticipants"))
                        .and_then(Value::as_u64)
                        .unwrap_or(0),
                })
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mic {
    /// Publishing and unmuted: others can hear them.
    On,
    Muted,
    /// No microphone track: they joined but never sent audio.
    None,
}

#[derive(Debug, Clone, PartialEq)]
pub struct VoiceMember {
    pub name: String,
    pub mic: Mic,
}

/// LiveKit's JSON uses enum names (`"AUDIO"`) or numbers (`1`) depending on
/// the server; both are accepted.
fn voice_member(p: &Value) -> VoiceMember {
    let is = |v: Option<&Value>, name: &str, number: u64| match v {
        Some(Value::String(s)) => s.eq_ignore_ascii_case(name),
        Some(Value::Number(n)) => n.as_u64() == Some(number),
        _ => false,
    };
    let audio = p.get("tracks").and_then(Value::as_array).and_then(|tracks| {
        tracks.iter().find(|t| is(t.get("type"), "AUDIO", 0) || is(t.get("source"), "MICROPHONE", 2))
    });
    let mic = match audio {
        None => Mic::None,
        Some(t) if t.get("muted").and_then(Value::as_bool) == Some(true) => Mic::Muted,
        Some(_) => Mic::On,
    };
    let name = p
        .get("name")
        .and_then(Value::as_str)
        .filter(|n| !n.is_empty())
        .or_else(|| p.get("identity").and_then(Value::as_str))
        .unwrap_or("Someone")
        .to_string();
    VoiceMember { name, mic }
}

/// [input] as a LiveKit WebSocket URL: `https`/`wss` (or a bare host) become
/// `wss`, `http`/`ws` become `ws`.
pub fn normalize_server_url(input: &str) -> Option<String> {
    let mut text = input.trim().to_string();
    if text.is_empty() {
        return None;
    }
    if !text.contains("://") {
        text = format!("wss://{text}");
    }
    let url = worker::Url::parse(&text).ok()?;
    let scheme = match url.scheme() {
        "https" | "wss" => "wss",
        "http" | "ws" => "ws",
        _ => return None,
    };
    let mut out = format!("{scheme}://{}", url.host_str()?);
    if let Some(port) = url.port() {
        out.push_str(&format!(":{port}"));
    }
    out.push_str(url.path().trim_end_matches('/'));
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_participants_and_mics() {
        let body = json!({"participants": [
            {"name": "Alice", "identity": "u1:d1", "tracks": [{"type": "AUDIO", "source": "MICROPHONE", "muted": false}]},
            {"name": "Bob", "identity": "u2:d2", "tracks": [{"type": 0, "muted": true}]},
            {"name": "", "identity": "u3:d3", "tracks": []},
        ]});
        let members: Vec<VoiceMember> = body["participants"].as_array().unwrap().iter().map(voice_member).collect();
        assert_eq!(members[0], VoiceMember { name: "Alice".into(), mic: Mic::On });
        assert_eq!(members[1].mic, Mic::Muted);
        assert_eq!(members[2], VoiceMember { name: "u3:d3".into(), mic: Mic::None });
        let rooms = rooms_from(&json!({"rooms": [{"name": "couchmates-ABC", "num_participants": 2}]}));
        assert_eq!(rooms[0].participants, 2);
    }

    #[test]
    fn normalizes_urls() {
        assert_eq!(normalize_server_url("https://x.livekit.cloud/").as_deref(), Some("wss://x.livekit.cloud"));
        assert_eq!(normalize_server_url("x.livekit.cloud").as_deref(), Some("wss://x.livekit.cloud"));
        assert_eq!(normalize_server_url("ws://10.0.0.2:7880").as_deref(), Some("ws://10.0.0.2:7880"));
        assert_eq!(normalize_server_url("ftp://x"), None);
    }
}
