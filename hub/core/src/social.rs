//! Who's watching what, and asking to join: the app's floating bubble.
//!
//! Each app posts its presence every 20 seconds or so ([`presence`]); the
//! answer lists everyone else. To stay inside the free plan's daily writes,
//! a device's row is only rewritten when what it plays changes, or once a
//! minute to keep it online.

use std::collections::HashMap;

use couchmates_core::api::{
    Activity, FriendActivity, FriendWatching, JoinRequest, JoinRequestAnswer, JoinRequestCancel, JoinRequestCreate,
    NowWatching, Person, PresenceUpdate,
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
    })
}

fn parse(json: Option<&str>) -> Option<NowWatching> {
    serde_json::from_str(json?).ok()
}

fn same_title(a: &NowWatching, b: &NowWatching) -> bool {
    a.meta_id == b.meta_id && a.episode == b.episode
}

/// What [row]'s device plays, if it's still online.
fn live(row: &PresenceRow, now: i64) -> Option<NowWatching> {
    if row.seen_at < now - ONLINE_SECS { None } else { parse(row.watching.as_deref()) }
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
    let mut people: HashMap<&str, (&str, i64, Option<i64>)> = HashMap::new();
    for r in rows.iter().filter(|r| r.user_id != me) {
        let entry = people.entry(&r.user_id).or_insert((&r.name, r.seen_at, r.photo_version));
        entry.1 = entry.1.max(r.seen_at);
    }
    let mut friends: Vec<FriendActivity> = people
        .into_iter()
        .map(|(id, (name, last_seen, photo))| FriendActivity {
            person: Person { id: id.into(), name: name.into(), photo: photo_path(id, photo) },
            online: last_seen >= now - ONLINE_SECS,
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
                    }
                } else {
                    Person { id: r.to_user.clone(), name: r.to_name.clone(), photo: photo_path(&r.to_user, r.to_photo) }
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
    let unchanged = stored.is_some_and(|r| r.watching == json && r.seen_at >= now - REWRITE_SECS);
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
    let watching = body.watching.and_then(clean);
    let mut rows = store.presence_rows().await?;
    let now = now();
    let stored = rows.iter().position(|r| r.device_id == device.id);
    if let Some((json, since)) = presence_write(stored.map(|i| &rows[i]), watching.as_ref(), now) {
        store.save_presence(&user.id, &device.id, now, json.as_deref(), since).await?;
        let row = PresenceRow {
            device_id: device.id.clone(),
            user_id: user.id.clone(),
            name: user.name.clone(),
            seen_at: now,
            watching: json,
            watching_since: since,
            photo_version: user.photo_version,
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
    fn clean_caps_text_and_drops_bad_rooms() {
        let w = NowWatching { title: "  x ".repeat(100), room: Some("!!".into()), ..watching("tt1", None) };
        let c = clean(w).unwrap();
        assert!(c.title.chars().count() <= 200 && c.room.is_none());
        assert!(clean(NowWatching { title: " ".into(), ..watching("tt1", None) }).is_none());
        assert_eq!(clean(watching("tt1", Some("K7M-Q2X"))).unwrap().room.as_deref(), Some("K7M-Q2X"));
    }
}
