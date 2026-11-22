//! Cast and crew from TMDB, for the app's details pages. Optional: without
//! a key in Hub Settings the app shows the catalog's names instead.

use couchmates_core::api::{CastMember, Credits, Extra};
use serde_json::Value;
use worker::{Fetch, Headers, Method, Request, RequestInit};

use crate::store::Store;

const API: &str = "https://api.themoviedb.org/3";
const PHOTOS: &str = "https://image.tmdb.org/t/p/w185";
const MAX_CAST: usize = 24;

pub struct Tmdb {
    key: String,
}

impl Tmdb {
    pub async fn load(store: &Store) -> worker::Result<Option<Self>> {
        Ok(store.setting("tmdb_key").await?.map(|key| Self { key }))
    }

    pub fn new(key: String) -> Self {
        Self { key }
    }

    /// TMDB takes a v4 read access token (a long JWT) as a bearer token, or
    /// a v3 API key as `api_key=`.
    fn is_bearer(&self) -> bool {
        self.key.starts_with("eyJ") && self.key.len() > 60
    }

    async fn get(&self, path: &str) -> Result<(u16, Value), String> {
        let headers = Headers::new();
        headers.set("accept", "application/json").map_err(|e| e.to_string())?;
        let mut url = format!("{API}{path}");
        if self.is_bearer() {
            headers.set("authorization", &format!("Bearer {}", self.key)).map_err(|e| e.to_string())?;
        } else {
            url.push(if url.contains('?') { '&' } else { '?' });
            url.push_str(&format!("api_key={}", self.key));
        }
        let mut init = RequestInit::new();
        init.with_method(Method::Get).with_headers(headers);
        let req = Request::new_with_init(&url, &init).map_err(|e| e.to_string())?;
        let mut resp = Fetch::Request(req).send().await.map_err(|e| format!("couldn't reach TMDB: {e}"))?;
        let status = resp.status_code();
        Ok((status, resp.json().await.unwrap_or(Value::Null)))
    }

    /// Checks the key works.
    pub async fn test(&self) -> Result<(), String> {
        match self.get("/configuration").await?.0 {
            200 => Ok(()),
            401 => Err("TMDB rejected the key".into()),
            s => Err(format!("TMDB answered {s}")),
        }
    }

    /// TMDB's id for an IMDb id, as (`movie` or `tv`, id).
    async fn find(&self, imdb: &str) -> Option<(&'static str, u64)> {
        let (status, v) = self.get(&format!("/find/{imdb}?external_source=imdb_id")).await.ok()?;
        if status != 200 {
            return None;
        }
        let first = |k: &str| {
            v.get(k).and_then(Value::as_array).and_then(|a| a.first()).and_then(|x| x.get("id")).and_then(Value::as_u64)
        };
        first("movie_results").map(|id| ("movie", id)).or_else(|| first("tv_results").map(|id| ("tv", id)))
    }

    /// Credits for a catalog title: [kind] is the catalog type (`movie` or
    /// `series`), [tmdb_id] the id Telegram-Stremio sends, [imdb] the
    /// fallback for finding it.
    pub async fn credits(&self, kind: &str, tmdb_id: Option<u64>, imdb: Option<&str>) -> Credits {
        let none = empty();
        let wanted = if kind == "series" { "tv" } else { "movie" };
        let target = match (tmdb_id, imdb) {
            (Some(id), _) => Some((wanted, id)),
            (None, Some(imdb)) => self.find(imdb).await,
            _ => None,
        };
        let Some((tv_or_movie, id)) = target else {
            return none;
        };
        // One request: the title plus its credits, age ratings and videos.
        let path = if tv_or_movie == "tv" {
            format!("/tv/{id}?append_to_response=aggregate_credits,content_ratings,videos")
        } else {
            format!("/movie/{id}?append_to_response=credits,release_dates,videos")
        };
        match self.get(&path).await {
            Ok((200, v)) => details_from(&v, tv_or_movie == "tv"),
            _ => none,
        }
    }
}

pub fn empty() -> Credits {
    Credits {
        available: false,
        cast: vec![],
        directors: vec![],
        writers: vec![],
        tagline: None,
        certification: None,
        studios: vec![],
        countries: vec![],
        released: None,
        videos: vec![],
    }
}

/// A title with `append_to_response` (credits, age ratings, videos) as ours.
pub fn details_from(v: &Value, tv: bool) -> Credits {
    let s = |x: &Value, k: &str| x.get(k).and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
    let names = |k: &str, max: usize| -> Vec<String> {
        v.get(k).and_then(Value::as_array).into_iter().flatten().filter_map(|x| s(x, "name")).take(max).collect()
    };
    let mut c = credits_from(v.get(if tv { "aggregate_credits" } else { "credits" }).unwrap_or(&Value::Null));
    // Shows name their creators rather than a director.
    if tv && c.directors.is_empty() {
        c.directors = names("created_by", 4);
    }
    c.tagline = s(v, "tagline");
    c.studios = names(if tv { "networks" } else { "production_companies" }, 3);
    c.countries = names("production_countries", 3);
    c.released = s(v, if tv { "first_air_date" } else { "release_date" });
    c.certification = certification(v, tv);
    c.videos = v
        .get("videos")
        .and_then(|x| x.get("results"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|x| s(x, "site").as_deref() == Some("YouTube"))
        .filter_map(|x| {
            Some(Extra { name: s(x, "name")?, kind: s(x, "type").unwrap_or_default(), youtube: s(x, "key")? })
        })
        .take(12)
        .collect();
    // Trailers first, then teasers, then the rest.
    c.videos.sort_by_key(|e| match e.kind.as_str() {
        "Trailer" => 0,
        "Teaser" => 1,
        _ => 2,
    });
    c.available = c.available || c.tagline.is_some() || !c.videos.is_empty();
    c
}

/// The US age rating, or the first one given.
fn certification(v: &Value, tv: bool) -> Option<String> {
    let results = v.get(if tv { "content_ratings" } else { "release_dates" })?.get("results")?.as_array()?;
    let rating_of = |r: &Value| -> Option<String> {
        if tv {
            r.get("rating").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string)
        } else {
            r.get("release_dates")?
                .as_array()?
                .iter()
                .filter_map(|d| d.get("certification").and_then(Value::as_str))
                .find(|c| !c.is_empty())
                .map(str::to_string)
        }
    };
    let us = results.iter().find(|r| r.get("iso_3166_1").and_then(Value::as_str) == Some("US")).and_then(rating_of);
    us.or_else(|| results.iter().find_map(rating_of))
}

/// TMDB's credits JSON (movie `credits` or tv `aggregate_credits`) as ours.
pub fn credits_from(v: &Value) -> Credits {
    let s = |x: &Value, k: &str| x.get(k).and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
    let cast: Vec<CastMember> = v
        .get("cast")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .take(MAX_CAST)
                .filter_map(|c| {
                    let character = s(c, "character").or_else(|| {
                        c.get("roles").and_then(Value::as_array).and_then(|r| r.first()).and_then(|r| s(r, "character"))
                    });
                    Some(CastMember {
                        name: s(c, "name")?,
                        character,
                        photo: s(c, "profile_path").map(|p| format!("{PHOTOS}{p}")),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let crew = |jobs: &[&str]| -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for c in v.get("crew").and_then(Value::as_array).into_iter().flatten() {
            let job = s(c, "job")
                .or_else(|| c.get("jobs").and_then(Value::as_array).and_then(|j| j.first()).and_then(|j| s(j, "job")));
            if job.is_some_and(|j| jobs.contains(&j.as_str())) {
                if let Some(name) = s(c, "name") {
                    if !out.contains(&name) {
                        out.push(name);
                    }
                }
            }
        }
        out.truncate(4);
        out
    };
    let directors = crew(&["Director"]);
    let writers = crew(&["Screenplay", "Writer", "Story", "Novel"]);
    Credits { available: !cast.is_empty() || !directors.is_empty(), cast, directors, writers, ..empty() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn movie_credits() {
        let v = json!({
            "cast": [
                {"name": "Keanu Reeves", "character": "Neo", "profile_path": "/abc.jpg"},
                {"name": "Carrie-Anne Moss", "character": "", "profile_path": null},
            ],
            "crew": [
                {"name": "Lana Wachowski", "job": "Director"},
                {"name": "Lana Wachowski", "job": "Writer"},
                {"name": "Bill Pope", "job": "Director of Photography"},
            ]
        });
        let c = credits_from(&v);
        assert!(c.available);
        assert_eq!(c.cast[0].photo.as_deref(), Some("https://image.tmdb.org/t/p/w185/abc.jpg"));
        assert_eq!(c.cast[1].character, None);
        assert_eq!(c.directors, vec!["Lana Wachowski"]);
        assert_eq!(c.writers, vec!["Lana Wachowski"]);
    }

    #[test]
    fn details_with_ratings_and_trailers() {
        let v = json!({
            "tagline": "Welcome to the Real World.",
            "release_date": "1999-03-30",
            "production_companies": [{"name": "Warner Bros. Pictures"}],
            "production_countries": [{"name": "United States of America"}],
            "credits": {"cast": [{"name": "Keanu Reeves", "character": "Neo"}], "crew": []},
            "release_dates": {"results": [
                {"iso_3166_1": "GB", "release_dates": [{"certification": "15"}]},
                {"iso_3166_1": "US", "release_dates": [{"certification": ""}, {"certification": "R"}]},
            ]},
            "videos": {"results": [
                {"site": "YouTube", "key": "f1", "name": "Behind the scenes", "type": "Featurette"},
                {"site": "Vimeo", "key": "x", "name": "Other", "type": "Trailer"},
                {"site": "YouTube", "key": "t1", "name": "Official Trailer", "type": "Trailer"},
            ]},
        });
        let d = details_from(&v, false);
        assert_eq!(d.certification.as_deref(), Some("R"));
        assert_eq!(d.tagline.as_deref(), Some("Welcome to the Real World."));
        assert_eq!(d.studios, vec!["Warner Bros. Pictures"]);
        assert_eq!(d.released.as_deref(), Some("1999-03-30"));
        assert_eq!(d.videos.iter().map(|e| e.youtube.as_str()).collect::<Vec<_>>(), vec!["t1", "f1"]);
        let tv = json!({"created_by": [{"name": "Vince Gilligan"}], "networks": [{"name": "AMC"}], "first_air_date": "2008-01-20",
            "content_ratings": {"results": [{"iso_3166_1": "US", "rating": "TV-MA"}]}, "aggregate_credits": {"cast": [], "crew": []}});
        let d = details_from(&tv, true);
        assert_eq!(
            (d.directors.clone(), d.certification.as_deref(), d.studios.clone()),
            (vec!["Vince Gilligan".to_string()], Some("TV-MA"), vec!["AMC".to_string()])
        );
    }

    #[test]
    fn show_aggregate_credits_use_roles() {
        let v = json!({"cast": [{"name": "Bryan Cranston", "roles": [{"character": "Walter White"}], "profile_path": "/w.jpg"}], "crew": []});
        assert_eq!(credits_from(&v).cast[0].character.as_deref(), Some("Walter White"));
    }
}
