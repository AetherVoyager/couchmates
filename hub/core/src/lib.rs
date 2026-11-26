//! Hub Core: everything the Hub does apart from drawing pages.
//!
//! - [`addons`]: public Stremio add-ons from the dashboard, and their
//!   compatibility check.
//! - [`store`]: the D1 database (settings, admin sessions, users, devices,
//!   usage history), with secrets sealed by [`crypto::Sealer`].
//! - [`auth`]: admin authenticator codes (TOTP) and app password hashing.
//! - [`tgs`]: the Telegram-Stremio admin API (access tokens, stats).
//! - [`catalog_check`]: why a user's app would show an empty catalog.
//! - [`livekit`]: voice join tokens and the room list.
//! - [`voice`]: LiveKit or direct voice, the TURN relay, direct voice rooms.
//! - [`voice_usage`]: how much the relay and LiveKit are used, for the Voice page.
//! - [`api`]: the app API handlers (`/api/app/*`), using the shapes in
//!   `couchmates-core`.
//! - [`tmdb`]: cast and crew for details pages.
//! - [`trackers`]: Trakt and Simkl linking and scrobbling.
//! - [`updates`]: app updates from GitHub Releases.
//! - [`social`]: who's watching what, and requests to join.
//! - [`jellyfin`]: a read-only Jellyfin look-alike for the admin's Tracearr.
//! - [`requests`]: titles friends ask the admin to add.
//! - [`bot`]: the bot API, for the admin's own program to answer requests.
//! - [`usage`]: data use per day.
//! - [`web`]: request and response helpers.

pub mod addons;
pub mod api;
pub mod auth;
pub mod bot;
pub mod catalog_check;
pub mod chat;
pub mod crypto;
pub mod jellyfin;
pub mod livekit;
pub mod opensubtitles;
pub mod requests;
pub mod social;
pub mod store;
pub mod tgs;
pub mod tmdb;
pub mod trackers;
pub mod updates;
pub mod usage;
pub mod voice;
pub mod voice_usage;
pub mod web;
