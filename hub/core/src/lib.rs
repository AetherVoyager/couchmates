//! Hub Core: everything the Hub does apart from drawing pages.
//!
//! - [`store`]: the D1 database (settings, admin sessions, users, devices,
//!   usage history), with secrets sealed by [`crypto::Sealer`].
//! - [`auth`]: admin authenticator codes (TOTP) and app password hashing.
//! - [`tgs`]: the Telegram-Stremio admin API (access tokens, stats).
//! - [`catalog_check`]: why a user's app would show an empty catalog.
//! - [`livekit`]: voice join tokens and the room list.
//! - [`api`]: the app API handlers (`/api/app/*`), using the shapes in
//!   `couchmates-core`.
//! - [`tmdb`]: cast and crew for details pages.
//! - [`trackers`]: Trakt and Simkl linking and scrobbling.
//! - [`updates`]: app updates from GitHub Releases.
//! - [`social`]: who's watching what, and requests to join.
//! - [`usage`]: data use per day.
//! - [`web`]: request and response helpers.

pub mod api;
pub mod auth;
pub mod catalog_check;
pub mod chat;
pub mod crypto;
pub mod livekit;
pub mod social;
pub mod store;
pub mod tgs;
pub mod tmdb;
pub mod trackers;
pub mod updates;
pub mod usage;
pub mod web;
