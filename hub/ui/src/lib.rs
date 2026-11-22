//! Hub UI: the dashboard's pages. Each function takes the data to show and
//! returns HTML; nothing here reads the database or calls a server. maud
//! escapes everything interpolated.

pub mod addons;
pub mod layout;
pub mod overview;
pub mod settings;
pub mod sign_in;
pub mod users;

pub use layout::Flash;
