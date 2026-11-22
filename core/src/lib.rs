//! Couchmates Core: what the Hub and the app agree on.
//!
//! - [`api`]: the request and response bodies of the app API (`/api/app/*`).
//!   `contract/*.json` holds a sample of each. The tests here and the app's
//!   tests in `app/core` both read them, so the two sides can't drift.
//! - [`rules`]: usernames, passwords and voice room names, checked the same
//!   way on both sides.
//!
//! No Cloudflare or platform code, so it builds and tests anywhere.

pub mod api;
pub mod rules;
