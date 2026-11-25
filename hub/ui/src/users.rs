//! The users list and a single user's page.

use couchmates_hub_core::catalog_check::{CatalogCheck, Rows};
use couchmates_hub_core::chat::CHAT_MUTED_FOREVER;
use couchmates_hub_core::store::{Device, User};
use maud::{Markup, html};

use crate::layout::{Flash, ago, layout, limit};

fn user_form(user: Option<&User>) -> Markup {
    html! {
        label for="name" { "Display name" }
        input #name type="text" name="name" required maxlength="60" value=[user.map(|u| u.name.as_str())];
        label for="username" { "Username (for signing in to the app)" }
        input #username type="text" name="username" required minlength="3" maxlength="32" autocomplete="off"
            autocapitalize="none" spellcheck="false" value=[user.and_then(|u| u.username.as_deref())];
        @if user.is_none() {
            label for="password" { "Password (leave blank to generate one)" }
            input #password type="text" name="password" autocomplete="off" spellcheck="false";
        }
        label for="daily" { "Daily data limit (GB, 0 = none)" }
        input #daily type="number" name="daily_limit_gb" min="0" step="0.5" value=(user.map_or(0.0, |u| u.daily_limit_gb));
        label for="monthly" { "Monthly data limit (GB, 0 = none)" }
        input #monthly type="number" name="monthly_limit_gb" min="0" step="1" value=(user.map_or(0.0, |u| u.monthly_limit_gb));
    }
}

/// The chat admin's verified badge.
fn verified() -> Markup {
    html! { span title="Chat admin" style="color:#1d9bf0" { "✔" } }
}

/// How long a chat mute ending at [until] has left.
fn mute_left(until: i64, now: i64) -> String {
    if until >= CHAT_MUTED_FOREVER {
        return "until you lift it".into();
    }
    let minutes = (until - now + 59) / 60;
    match minutes {
        ..=119 => format!("for another {minutes} min"),
        120..=2879 => format!("for another {} h", (minutes + 59) / 60),
        _ => format!("for another {} days", (minutes + 1439) / 1440),
    }
}

fn chat_card(user: &User, base: &str, now: i64) -> Markup {
    html! {
        div.card {
            h2 { "Chat" }
            div.row {
                @if user.is_chat_admin() {
                    span.pill.ok { "Chat admin " (verified()) }
                    form.inline method="post" action=(format!("{base}/chat-unadmin")) {
                        button.secondary type="submit" { "Remove chat admin" }
                    }
                } @else {
                    form.inline method="post" action=(format!("{base}/chat-admin")) {
                        button.secondary type="submit" { "Make chat admin" }
                    }
                }
            }
            p.muted {
                "Chat admins have a verified badge next to their name. In the app they can delete anyone's message "
                "in the Everyone chat and mute people. They're never muted or slowed down."
            }
            @if !user.is_chat_admin() {
                @if let Some(until) = user.muted_until(now) {
                    p { span.pill.warn { "Muted" } " " (mute_left(until, now)) ". They can read but not send messages." }
                    form.inline method="post" action=(format!("{base}/chat-unmute")) {
                        button type="submit" { "Lift the mute" }
                    }
                } @else {
                    form method="post" action=(format!("{base}/chat-mute")) {
                        label for="mute_minutes" { "Stop them sending chat messages" }
                        select #mute_minutes name="minutes" {
                            option value="60" { "For 1 hour" }
                            option value="1440" { "For 1 day" }
                            option value="10080" { "For 1 week" }
                            option value="forever" { "Until I lift it" }
                        }
                        div.row { button.secondary type="submit" { "Mute" } }
                    }
                }
            }
        }
    }
}

pub fn list(users: &[User], now: i64, flash: Option<&Flash>) -> Markup {
    let body = html! {
        h1 { "Users" }
        div.card {
            h2 { "Add a user" }
            p.muted { "They sign in to the Couchmates app with this username and password. Nothing else to set up on their side." }
            form method="post" action="/users" {
                (user_form(None))
                div.row { button type="submit" { "Create user" } }
            }
        }
        div.card {
            h2 { "Everyone" }
            @if users.is_empty() { p.muted { "No users yet." } }
            @else {
                table {
                    tr { th { "Name" } th { "Username" } th { "Limits" } th { "Status" } th { "Added" } }
                    @for u in users {
                        tr {
                            td { a href=(format!("/users/{}", u.id)) { (u.name) } @if u.is_chat_admin() { " " (verified()) } }
                            td { (u.username.as_deref().unwrap_or("—")) }
                            td { (limit(u.daily_limit_gb)) " / day · " (limit(u.monthly_limit_gb)) " / month" }
                            td {
                                @if u.disabled != 0 { span.pill.bad { "Disabled" } } @else { span.pill.ok { "Active" } }
                                @if u.muted_until(now).is_some() { " " span.pill.warn { "Muted in chat" } }
                            }
                            td { (ago(now, u.created_at)) }
                        }
                    }
                }
            }
        }
    };
    layout("Users", "/users", flash, body)
}

pub struct UserPage<'a> {
    pub user: &'a User,
    pub devices: &'a [Device],
    /// This Hub's address, for the sign-in details.
    pub hub: &'a str,
    /// A just-generated password, shown once.
    pub new_password: Option<&'a str>,
    /// Linked trackers: service and account name.
    pub trackers: &'a [(String, Option<String>)],
    /// The result of "Check catalog", when just run.
    pub catalog_check: Option<&'a CatalogCheck>,
    pub now: i64,
}

pub fn detail(data: &UserPage, flash: Option<&Flash>) -> Markup {
    let UserPage { user, devices, hub, now, .. } = *data;
    let base = format!("/users/{}", user.id);
    let body = html! {
        h1 { (user.name) " " @if user.is_chat_admin() { (verified()) " " } @if user.disabled != 0 { span.pill.bad { "Disabled" } } }
        @if let Some(password) = data.new_password {
            div.card {
                h2 { "Sign-in details" }
                p { "Send these to " (user.name) ". In the Couchmates app they enter:" }
                table {
                    tr { th { "Hub address" } td { code { (hub) } } }
                    tr { th { "Username" } td { code { (user.username.as_deref().unwrap_or("")) } } }
                    tr { th { "Password" } td { span.code { (password) } } }
                }
                p.muted { "The password is only shown now. They can change it in the app." }
            }
        }
        div.card {
            h2 { "Details" }
            form method="post" action=(format!("{base}/update")) {
                (user_form(Some(user)))
                div.row { button type="submit" { "Save" } }
            }
        }
        div.card {
            h2 { "Password" }
            form method="post" action=(format!("{base}/password")) {
                label for="new_password" { "New password (leave blank to generate one)" }
                input #new_password type="text" name="password" autocomplete="off" spellcheck="false";
                div.row { button.secondary type="submit" { "Set new password" } }
            }
            p.muted { "Setting a new password signs them out of every device." }
        }
        div.card {
            h2 { "Devices" }
            @if devices.is_empty() { p.muted { "Not signed in on any device." } }
            @else {
                table {
                    tr { th { "Device" } th { "Signed in" } th { "Last seen" } th {} }
                    @for d in devices {
                        tr {
                            td { (d.name) } td { (ago(now, d.created_at)) } td { (ago(now, d.last_seen)) }
                            td { form.inline method="post" action=(format!("{base}/devices/{}/delete", d.id)) { button.secondary type="submit" { "Sign out" } } }
                        }
                    }
                }
            }
        }
        @if !data.trackers.is_empty() {
            div.card {
                h2 { "Trackers" }
                p {
                    @for (i, (service, name)) in data.trackers.iter().enumerate() {
                        @if i > 0 { " · " }
                        span.pill.ok { (service) @if let Some(n) = name { ": " (n) } }
                    }
                }
                p.muted { "Linked by the user in the app. They can unlink in the app's settings." }
            }
        }
        (chat_card(user, &base, now))
        div.card {
            h2 { "Catalog" }
            p.muted { "See what this user's app gets from Telegram-Stremio, using their own access token." }
            @if let Some(check) = data.catalog_check {
                div class=(if check.ok { "flash ok" } else { "flash bad" }) { (check.verdict) }
                @if !check.catalogs.is_empty() {
                    table {
                        tr { th { "Catalog" } th { "First page" } }
                        @for c in &check.catalogs {
                            tr {
                                td { (c.label) }
                                td {
                                    @match &c.rows {
                                        Rows::Titles(n) => { (n) " titles" },
                                        Rows::Failed(status, why) => span.pill.bad { "Failed " (status) " " (why) },
                                    }
                                }
                            }
                        }
                    }
                }
                @if let Some(n) = check.library_titles {
                    p.muted { "Whole library: " (n) " movies and shows." }
                }
            }
            div.row {
                form.inline method="post" action=(format!("{base}/check-catalog")) {
                    button.secondary type="submit" { "Check catalog" }
                }
                @if data.catalog_check.is_some_and(|c| c.hide_catalog == Some(true)) {
                    form.inline method="post" action="/settings/tgs/show-catalog" {
                        button type="submit" { "Turn off Hide Catalog" }
                    }
                }
            }
        }
        div.card {
            h2 { "Access" }
            div.row {
                @if user.disabled != 0 {
                    form.inline method="post" action=(format!("{base}/enable")) { button type="submit" { "Enable" } }
                } @else {
                    form.inline method="post" action=(format!("{base}/disable")) { button.secondary type="submit" { "Disable" } }
                }
                form.inline method="post" action=(format!("{base}/delete")) { button.danger type="submit" { "Delete user" } }
            }
            p.muted { "Disabling stops their playback right away and blocks the app until you enable them again." }
        }
    };
    layout(&user.name, "/users", flash, body)
}
