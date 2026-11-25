//! Who's watching what, and asking to join: the app's floating bubble.
//!
//! Each app posts its presence every 20 seconds or so ([`presence`]); the
//! answer lists everyone else. To stay inside the free plan's daily writes,
//! a device's row is only rewritten when what it plays changes, once a
//! minute to keep it online, or when the position jumps (a seek). An app that
//! closes says so (`leaving`), and its device goes offline at once instead of
//! [`ONLINE_SECS`] after its reports stop.

use std::collections::HashMap;

use couchmates_core::api::{
    Activity, FriendActivity, FriendWatching, JoinRequest, JoinRequestAnswer, JoinRequestCancel, JoinRequestCreate,
    NowWatching, Person, PlaybackInfo, PresenceUpdate,
};
use couchmates_core::rules::room_for_watch_code;
use worker::{Request, Response, Result};

use crate::api::{authenticate, photo_path};
use crate::store::{JoinRow, PresenceRow, Store, now};
use crate::web::{self, json_error};

/// The app was open this recently: online, and what it plays still counts.
pub const ONLINE_SECS: i64 = 90;
/// A row younger than this isn't rewritten unless what's playing changed.
const REWRITE_SECS: i64 = 60;
/// A position this far from where the stored one has run to is a seek, and
/// is written straight away.
const SEEK_MS: i64 = 15_000;
/// Pending requests last this long, and answered ones stay listed this long.
pub const REQUEST_SECS: i64 = 120;

fn capped(text: &str, max: usize) -> String {
    text.trim().chars().take(max).collect()
}

/// [watching] with its text trimmed and capped, and a room that isn't a room
/// code dropped. None when it has no title or id.
pub fn clean(watching: NowWatching) -> Option<NowWatching> {
    let title = capped(&watching.title, 200);
    let meta_id = capped(&watching.meta_id, 120);
    if title.is_empty() || meta_id.is_empty() {
        return None;
    }
    Some(NowWatching {
        title,
        episode: watching.episode.map(|e| capped(&e, 200)).filter(|e| !e.is_empty()),
        meta_type: capped(&watching.meta_type, 20),
        meta_id,
        paused: watching.paused,
        room: watching.room.map(|r| capped(&r, 32)).filter(|r| room_for_watch_code(r).is_some()),
        poster: watching.poster.filter(|p| p.starts_with("https://") && p.len() <= 500),
        playback: watching.playback.map(clean_playback),
        private: watching.private,
    })
}

fn clean_playback(p: PlaybackInfo) -> PlaybackInfo {
    let short = |t: Option<String>| t.map(|t| capped(&t, 20)).filter(|t| !t.is_empty());
    PlaybackInfo {
        position_ms: p.position_ms.max(0),
        duration_ms: p.duration_ms.filter(|d| *d > 0),
        width: p.width.filter(|w| *w > 0 && *w <= 16_384),
        height: p.height.filter(|h| *h > 0 && *h <= 16_384),
        video_codec: short(p.video_codec),
        audio_codec: short(p.audio_codec),
        audio_channels: p.audio_channels.filter(|c| *c > 0 && *c <= 32),
        bitrate: p.bitrate.filter(|b| *b > 0),
    }
}

/// Where [w]'s player is [elapsed_secs] after it reported, if it kept playing.
pub fn position_after(w: &NowWatching, elapsed_secs: i64) -> Option<i64> {
    let p = w.playback.as_ref()?;
    let moved = if w.paused { 0 } else { elapsed_secs.max(0) * 1000 };
    let at = p.position_ms + moved;
    Some(p.duration_ms.map_or(at, |d| at.min(d)))
}

pub fn parse(json: Option<&str>) -> Option<NowWatching> {
    serde_json::from_str(json?).ok()
}

fn same_title(a: &NowWatching, b: &NowWatching) -> bool {
    a.meta_id == b.meta_id && a.episode == b.episode
}

/// [row]'s device reported recently and hasn't said it's closing.
pub fn online(row: &PresenceRow, now: i64) -> bool {
    row.offline == 0 && row.seen_at >= now - ONLINE_SECS
}

/// What [row]'s device plays, if it's still online, whether or not it's
/// shared with friends.
pub fn live_any(row: &PresenceRow, now: i64) -> Option<NowWatching> {
    if online(row, now) { parse(row.watching.as_deref()) } else { None }
}

/// What [row]'s device plays, if it's still online and shared with friends.
fn live(row: &PresenceRow, now: i64) -> Option<NowWatching> {
    live_any(row, now).filter(|w| !w.private)
}

/// The freshest online device of [user_id] that's playing something.
fn playing(user_id: &str, rows: &[PresenceRow], now: i64) -> Option<(NowWatching, i64)> {
    rows.iter()
        .filter(|r| r.user_id == user_id)
        .filter_map(|r| Some((live(r, now)?, r.watching_since.unwrap_or(r.seen_at), r.seen_at)))
        .max_by_key(|(_, _, seen)| *seen)
        .map(|(w, since, _)| (w, since))
}

/// What everyone but [me] is up to, and [me]'s join requests.
pub fn activity(me: &str, rows: &[PresenceRow], requests: &[JoinRow], now: i64) -> Activity {
    let mut people: HashMap<&str, (&str, i64, Option<i64>, bool, bool)> = HashMap::new();
    for r in rows.iter().filter(|r| r.user_id != me) {
        let entry = people.entry(&r.user_id).or_insert((&r.name, r.seen_at, r.photo_version, r.chat_admin != 0, false));
        entry.1 = entry.1.max(r.seen_at);
        entry.4 |= online(r, now);
    }
    let mut friends: Vec<FriendActivity> = people
        .into_iter()
        .map(|(id, (name, last_seen, photo, admin, online))| FriendActivity {
            person: Person { id: id.into(), name: name.into(), photo: photo_path(id, photo), admin },
            online,
            last_seen,
            watching: playing(id, rows, now).map(|(w, since)| FriendWatching {
                title: w.title,
                episode: w.episode,
                meta_type: w.meta_type,
                meta_id: w.meta_id,
                paused: w.paused,
                in_party: w.room.is_some(),
                since,
            }),
        })
        .collect();
    friends.sort_by(|a, b| {
        (b.watching.is_some(), b.online)
            .cmp(&(a.watching.is_some(), a.online))
            .then_with(|| a.person.name.to_lowercase().cmp(&b.person.name.to_lowercase()))
    });

    let requests = requests
        .iter()
        .filter_map(|r| {
            let incoming = r.to_user == me;
            let fresh = match r.status.as_str() {
                "pending" => r.created_at >= now - REQUEST_SECS,
                _ => !incoming && r.answered_at.unwrap_or(0) >= now - REQUEST_SECS,
            };
            fresh.then(|| JoinRequest {
                id: r.id.clone(),
                incoming,
                person: if incoming {
                    Person {
                        id: r.from_user.clone(),
                        name: r.from_name.clone(),
                        photo: photo_path(&r.from_user, r.from_photo),
                        admin: false,
                    }
                } else {
                    Person {
                        id: r.to_user.clone(),
                        name: r.to_name.clone(),
                        photo: photo_path(&r.to_user, r.to_photo),
                        admin: false,
                    }
                },
                title: r.title.clone(),
                status: r.status.clone(),
                room: if incoming || r.status != "accepted" { None } else { r.room.clone() },
                created_at: r.created_at,
            })
        })
        .collect();
    Activity { friends, requests }
}

/// Whether [device_id]'s row needs writing, and the `since` to write.
pub fn presence_write(
    stored: Option<&PresenceRow>,
    watching: Option<&NowWatching>,
    now: i64,
) -> Option<(Option<String>, Option<i64>)> {
    let json = watching.and_then(|w| serde_json::to_string(w).ok());
    let old = stored.and_then(|r| parse(r.watching.as_deref()));
    let since = match (watching, &old) {
        (None, _) => None,
        (Some(w), Some(o)) if same_title(w, o) => stored.and_then(|r| r.watching_since).or(Some(now)),
        (Some(_), _) => Some(now),
    };
    // The position moves on every report, so it only counts when it jumps.
    let unchanged = stored.is_some_and(|r| {
        r.seen_at >= now - REWRITE_SECS
            && match (watching, &old) {
                (None, None) => true,
                (Some(w), Some(o)) => {
                    let still = |x: &NowWatching| NowWatching { playback: None, ..x.clone() };
                    let drift = match (w.playback.as_ref(), position_after(o, now - r.seen_at)) {
                        (Some(p), Some(expected)) => (p.position_ms - expected).abs(),
                        (None, None) => 0,
                        _ => i64::MAX,
                    };
                    let format =
                        |x: &NowWatching| x.playback.as_ref().map(|p| PlaybackInfo { position_ms: 0, ..p.clone() });
                    still(w) == still(o) && format(w) == format(o) && drift < SEEK_MS
                }
                _ => false,
            }
    });
    (!unchanged).then_some((json, since))
}

async fn respond(store: &Store, me: &str, rows: &[PresenceRow]) -> Result<Response> {
    let now = now();
    let requests = store.join_requests_for(me, now - REQUEST_SECS).await?;
    web::json(&activity(me, rows, &requests, now), 200)
}

/// `POST /api/app/presence`.
pub async fn presence(mut req: Request, store: &Store) -> Result<Response> {
    let (device, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<PresenceUpdate>().await else {
        return json_error("Send {\"watching\": … or null}.", 400);
    };
    let leaving = body.leaving;
    let watching = if leaving { None } else { body.watching.and_then(clean) };
    let mut rows = store.presence_rows().await?;
    let now = now();
    let ip = web::client_ip(&req);
    let stored = rows.iter().position(|r| r.device_id == device.id);
    let moved = stored.is_some_and(|i| rows[i].ip.as_deref() != Some(ip.as_str()));
    // Going offline, or coming back from it, is always written.
    let flipped = stored.is_some_and(|i| (rows[i].offline != 0) != leaving);
    let write = presence_write(stored.map(|i| &rows[i]), watching.as_ref(), now).or_else(|| {
        (moved || flipped)
            .then(|| (stored.and_then(|i| rows[i].watching.clone()), stored.and_then(|i| rows[i].watching_since)))
    });
    if let Some((json, since)) = write {
        store.save_presence(&user.id, &device.id, now, json.as_deref(), since, &ip, leaving).await?;
        let row = PresenceRow {
            device_id: device.id.clone(),
            user_id: user.id.clone(),
            name: user.name.clone(),
            seen_at: now,
            watching: json,
            watching_since: since,
            photo_version: user.photo_version,
            ip: Some(ip),
            device_name: Some(device.name.clone()),
            chat_admin: user.chat_admin,
            offline: leaving as i64,
        };
        match stored {
            Some(i) => rows[i] = row,
            None => rows.push(row),
        }
    }
    respond(store, &user.id, &rows).await
}

/// `POST /api/app/join-requests`: asks someone who's watching to let this
/// user join.
pub async fn create_join_request(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<JoinRequestCreate>().await else {
        return json_error("Send {\"to_user_id\": \"…\"}.", 400);
    };
    if body.to_user_id == user.id {
        return json_error("That's you.", 400);
    }
    let rows = store.presence_rows().await?;
    let Some((watching, _)) = playing(&body.to_user_id, &rows, now()) else {
        return json_error("They aren't watching anything right now.", 409);
    };
    store.create_join_request(&user.id, &body.to_user_id, &watching.title).await?;
    respond(store, &user.id, &rows).await
}

/// `POST /api/app/join-requests/answer`: accept with a room, or decline.
pub async fn answer_join_request(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<JoinRequestAnswer>().await else {
        return json_error("Send {\"id\": \"…\", \"accept\": true}.", 400);
    };
    let found = store.join_request(&body.id).await?;
    let Some(request) = found.filter(|r| r.to_user == user.id) else {
        return json_error("That request is gone.", 404);
    };
    if request.status != "pending" || request.created_at < now() - REQUEST_SECS {
        return json_error("That request has expired.", 410);
    }
    let rows = store.presence_rows().await?;
    if body.accept {
        let given = body.room.as_deref().map(|r| capped(r, 32)).filter(|r| room_for_watch_code(r).is_some());
        let current = || rows.iter().filter(|r| r.user_id == user.id).filter_map(|r| live(r, now())?.room).next();
        let Some(room) = given.or_else(current) else {
            return json_error("Start a watch party first, then accept.", 409);
        };
        store.answer_join_request(&request.id, "accepted", Some(&room)).await?;
    } else {
        store.answer_join_request(&request.id, "declined", None).await?;
    }
    respond(store, &user.id, &rows).await
}

/// `POST /api/app/join-requests/cancel`.
pub async fn cancel_join_request(mut req: Request, store: &Store) -> Result<Response> {
    let (_, user) = match authenticate(&req, store).await? {
        Ok(v) => v,
        Err(r) => return Ok(r),
    };
    let Ok(body) = req.json::<JoinRequestCancel>().await else {
        return json_error("Send {\"id\": \"…\"}.", 400);
    };
    store.delete_join_request(&body.id, &user.id).await?;
    let rows = store.presence_rows().await?;
    respond(store, &user.id, &rows).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn watching(id: &str, room: Option<&str>) -> NowWatching {
        NowWatching {
            title: format!("Title {id}"),
            episode: None,
            meta_type: "movie".into(),
            meta_id: id.into(),
            paused: false,
            room: room.map(Into::into),
            poster: None,
            playback: None,
            private: false,
        }
    }

    fn row(device: &str, user: &str, seen_at: i64, w: Option<NowWatching>) -> PresenceRow {
        PresenceRow {
            device_id: device.into(),
            user_id: user.into(),
            name: user.to_uppercase(),
            seen_at,
            watching: w.map(|w| serde_json::to_string(&w).unwrap()),
            watching_since: Some(seen_at - 100),
            photo_version: (user == "bob").then_some(7),
            ip: None,
            device_name: None,
            chat_admin: 0,
            offline: 0,
        }
    }

    fn join(id: &str, from: &str, to: &str, status: &str, created: i64, answered: Option<i64>) -> JoinRow {
        JoinRow {
            id: id.into(),
            from_user: from.into(),
            from_name: from.to_uppercase(),
            to_user: to.into(),
            to_name: to.to_uppercase(),
            title: "T".into(),
            status: status.into(),
            room: (status == "accepted").then(|| "K7MQ2X".into()),
            created_at: created,
            answered_at: answered,
            from_photo: None,
            to_photo: None,
        }
    }

    #[test]
    fn lists_others_watching_first_and_ignores_stale_devices() {
        let now = 10_000;
        let rows = vec![
            row("d0", "me", now, Some(watching("tt0", None))),
            row("d1", "bob", now - 5, None),
            // Bob's TV is playing; his idle laptop doesn't hide it.
            row("d2", "bob", now - 10, Some(watching("tt1", Some("K7MQ2X")))),
            row("d3", "carol", now - 500, Some(watching("tt2", None))),
            row("d4", "ann", now - 20, None),
        ];
        let a = activity("me", &rows, &[], now);
        let names: Vec<_> = a.friends.iter().map(|f| f.person.name.as_str()).collect();
        assert_eq!(names, ["BOB", "ANN", "CAROL"]);
        let bob = a.friends[0].watching.as_ref().unwrap();
        assert!(bob.in_party && bob.meta_id == "tt1");
        assert_eq!(a.friends[0].person.photo.as_deref(), Some("/api/app/photos/bob?v=7"));
        assert_eq!(a.friends[1].person.photo, None);
        assert!(!a.friends[2].online && a.friends[2].watching.is_none());
    }

    #[test]
    fn room_codes_only_reach_accepted_requesters() {
        let now = 10_000;
        let requests = vec![
            join("r1", "bob", "me", "pending", now - 10, None),
            join("r2", "me", "carol", "accepted", now - 30, Some(now - 5)),
            join("r3", "ann", "me", "accepted", now - 30, Some(now - 5)),
            join("r4", "me", "dan", "pending", now - 500, None),
        ];
        let a = activity("me", &[], &requests, now);
        let ids: Vec<_> = a.requests.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["r1", "r2"]);
        assert!(a.requests[0].incoming && a.requests[0].room.is_none());
        assert_eq!(a.requests[1].room.as_deref(), Some("K7MQ2X"));
        assert_eq!(a.requests[1].person.name, "CAROL");
    }

    #[test]
    fn rewrites_only_on_change_or_once_a_minute() {
        let now = 10_000;
        let w = watching("tt1", None);
        let stored = row("d", "me", now - 20, Some(w.clone()));
        assert_eq!(presence_write(Some(&stored), Some(&w), now), None);
        let (_, since) = presence_write(Some(&row("d", "me", now - 61, Some(w.clone()))), Some(&w), now).unwrap();
        assert_eq!(since, Some(now - 161), "same title keeps its start");
        let paused = NowWatching { paused: true, ..w.clone() };
        assert!(presence_write(Some(&stored), Some(&paused), now).is_some());
        let (_, since) = presence_write(Some(&stored), Some(&watching("tt9", None)), now).unwrap();
        assert_eq!(since, Some(now));
        assert_eq!(presence_write(None, None, now), Some((None, None)));
    }

    #[test]
    fn a_closed_app_is_offline_at_once() {
        let now = 10_000;
        let gone = PresenceRow { offline: 1, ..row("d1", "bob", now - 5, Some(watching("tt1", Some("K7MQ2X")))) };
        let rows = vec![gone.clone(), row("d2", "ann", now - 5, None)];
        let a = activity("me", &rows, &[], now);
        let bob = a.friends.iter().find(|f| f.person.id == "bob").unwrap();
        assert!(!bob.online && bob.watching.is_none() && bob.last_seen == now - 5);
        assert!(playing("bob", &rows, now).is_none() && live_any(&gone, now).is_none());
        // Bob's other device, still open, keeps him online.
        let rows = vec![gone, row("d3", "bob", now - 5, None)];
        assert!(activity("me", &rows, &[], now).friends[0].online);
    }

    #[test]
    fn private_watching_stays_off_the_friends_list() {
        let now = 10_000;
        let hidden = NowWatching { private: true, ..watching("tt1", None) };
        let rows = vec![row("d1", "bob", now, Some(hidden))];
        let a = activity("me", &rows, &[], now);
        assert!(a.friends[0].online && a.friends[0].watching.is_none());
        assert!(playing("bob", &rows, now).is_none());
        assert!(live_any(&rows[0], now).is_some());
    }

    #[test]
    fn position_only_rewrites_on_a_seek() {
        let now = 10_000;
        let at = |ms: i64, paused: bool| NowWatching {
            paused,
            playback: Some(PlaybackInfo { position_ms: ms, duration_ms: Some(600_000), ..Default::default() }),
            ..watching("tt1", None)
        };
        let stored = row("d", "me", now - 20, Some(at(100_000, false)));
        // 20 seconds on, the player is 20 seconds further: nothing to write.
        assert_eq!(presence_write(Some(&stored), Some(&at(121_000, false)), now), None);
        // A seek is written.
        assert!(presence_write(Some(&stored), Some(&at(400_000, false)), now).is_some());
        // Paused, the position stands still.
        let paused = row("d", "me", now - 20, Some(at(100_000, true)));
        assert_eq!(presence_write(Some(&paused), Some(&at(100_500, true)), now), None);
        assert!(presence_write(Some(&paused), Some(&at(130_000, true)), now).is_some());
        assert_eq!(position_after(&at(590_000, false), 60), Some(600_000), "never past the end");
    }

    #[test]
    fn clean_caps_text_and_drops_bad_rooms() {
        let w = NowWatching { title: "  x ".repeat(100), room: Some("!!".into()), ..watching("tt1", None) };
        let c = clean(w).unwrap();
        assert!(c.title.chars().count() <= 200 && c.room.is_none());
        assert!(clean(NowWatching { title: " ".into(), ..watching("tt1", None) }).is_none());
        assert_eq!(clean(watching("tt1", Some("K7M-Q2X"))).unwrap().room.as_deref(), Some("K7M-Q2X"));
        let poster = |p: &str| NowWatching { poster: Some(p.into()), ..watching("tt1", None) };
        assert_eq!(clean(poster("http://x/p.jpg")).unwrap().poster, None);
        assert!(clean(poster("https://x/p.jpg")).unwrap().poster.is_some());
    }
}
