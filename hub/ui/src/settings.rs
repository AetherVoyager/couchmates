//! The settings page: Telegram-Stremio, LiveKit, the voice relay, the Hub address and 2FA.

use maud::{Markup, html};

use crate::layout::{Flash, layout};

/// The saved settings. Secrets only say whether one is saved.
pub struct Settings<'a> {
    pub tgs_url: Option<&'a str>,
    pub tgs_username: Option<&'a str>,
    pub tgs_has_password: bool,
    /// Telegram-Stremio's "Hide Catalog", when connected and readable.
    pub tgs_hide_catalog: Option<bool>,
    pub livekit_url: Option<&'a str>,
    pub livekit_key: Option<&'a str>,
    pub livekit_has_secret: bool,
    /// `livekit` or `direct`.
    pub voice_mode: &'a str,
    /// The TURN relay as `host:port`.
    pub turn_server: Option<&'a str>,
    pub turn_has_secret: bool,
    pub turn_username: Option<&'a str>,
    pub turn_has_password: bool,
    pub github_repo: Option<&'a str>,
    pub github_has_token: bool,
    pub trakt_client_id: Option<&'a str>,
    pub trakt_has_secret: bool,
    pub simkl_client_id: Option<&'a str>,
    pub tmdb_has_key: bool,
    /// Tracearr can read the Hub's Jellyfin-style API.
    pub tracearr_has_key: bool,
    /// A Tracearr key just made, shown this once.
    pub tracearr_new_key: Option<&'a str>,
    /// The chat's blocked words, as typed.
    pub chat_blocked_words: Option<&'a str>,
    pub hub: &'a str,
}

pub fn page(s: &Settings, flash: Option<&Flash>) -> Markup {
    let body = html! {
        h1 { "Settings" }
        div.card {
            h2 { "Telegram-Stremio" }
            p.muted { "Your server's public address and its web panel admin login. The Hub signs in like the panel does to manage access tokens and read stats." }
            form method="post" action="/settings/tgs" {
                label for="tgs_url" { "Server address" }
                input #tgs_url type="url" name="url" required placeholder="https://tg.example.com" value=[s.tgs_url];
                label for="tgs_username" { "Admin username" }
                input #tgs_username type="text" name="username" required autocomplete="off" value=[s.tgs_username];
                label for="tgs_password" { "Admin password" @if s.tgs_has_password { " (leave blank to keep the saved one)" } }
                input #tgs_password type="password" name="password" autocomplete="new-password" required[!s.tgs_has_password];
                div.row { button type="submit" { "Save and test" } }
            }
            @if s.tgs_hide_catalog == Some(true) {
                div.flash.bad {
                    "\"Hide Catalog\" is on in Telegram-Stremio, so the app can't show any rows. Despite its description it "
                    "hides catalogs from every token, including your users'. Streams still need each user's token."
                }
                form method="post" action="/settings/tgs/show-catalog" {
                    div.row { button type="submit" { "Turn off Hide Catalog" } }
                }
            }
        }
        div.card {
            h2 { "LiveKit voice chat" }
            p.muted { "From LiveKit Cloud (Settings → API keys) or your own server. The secret stays on the Hub; apps get short-lived voice tokens from it." }
            form method="post" action="/settings/livekit" {
                label for="lk_url" { "Server URL" }
                input #lk_url type="text" name="url" required placeholder="wss://your-project.livekit.cloud" value=[s.livekit_url];
                label for="lk_key" { "API key" }
                input #lk_key type="text" name="key" required autocomplete="off" value=[s.livekit_key];
                label for="lk_secret" { "API secret" @if s.livekit_has_secret { " (leave blank to keep the saved one)" } }
                input #lk_secret type="password" name="secret" autocomplete="new-password" required[!s.livekit_has_secret];
                div.row { button type="submit" { "Save and test" } }
            }
        }
        div.card #voice-relay {
            h2 { "Voice relay (TURN)" }
            p.muted {
                "Optional. Your own TURN server (coturn), for direct voice: the apps in a watch party talk to each other "
                "peer to peer, and go through this relay when they can't reach each other (mobile data, shared NAT). "
                "The login stays on the Hub; apps get it only while signed in. With a shared secret (coturn's "
                "use-auth-secret and static-auth-secret) each app gets a login that expires after 6 hours; otherwise "
                "enter a fixed username and password from the relay's turnserver.conf."
            }
            form method="post" action="/settings/voice" {
                label { "Voice chat uses" }
                div.row {
                    label { input type="radio" name="mode" value="livekit" checked[s.voice_mode != "direct"]; " LiveKit" }
                    label { input type="radio" name="mode" value="direct" checked[s.voice_mode == "direct"]; " Direct, through this relay" }
                }
                p.muted { "Apps pick up a switch the next time they join voice. Direct voice suits a few people at a time, and needs the app version that added it on every device." }
                label for="turn_server" { "Relay address" }
                input #turn_server type="text" name="server" placeholder="203.0.113.5:3478" value=[s.turn_server];
                label for="turn_secret" { "Shared secret" @if s.turn_has_secret { " (saved; leave blank to keep it, or type 'remove')" } }
                input #turn_secret type="password" name="secret" autocomplete="new-password";
                label for="turn_user" { "Or a fixed username" }
                input #turn_user type="text" name="username" autocomplete="off" value=[s.turn_username];
                label for="turn_pass" { "and its password" @if s.turn_has_password { " (saved; leave blank to keep it)" } }
                input #turn_pass type="password" name="password" autocomplete="new-password";
                div.row { button type="submit" { "Save" } }
            }
        }
        div.card {
            h2 { "App updates" }
            p.muted {
                "Apps check here for new versions. The Hub reads the newest versioned release (not the \"Latest build\" pre-release) "
                "from the private GitHub repo and gives signed-in apps a short-lived download link. Make a fine-grained token on GitHub "
                "(Settings → Developer settings → Fine-grained tokens) with access to just this repo and Contents: Read-only."
            }
            form method="post" action="/settings/updates" {
                label for="gh_repo" { "Repository" }
                input #gh_repo type="text" name="repo" required placeholder="AetherVoyager/couchmates" value=[s.github_repo];
                label for="gh_token" { "GitHub token" @if s.github_has_token { " (leave blank to keep the saved one)" } }
                input #gh_token type="password" name="token" autocomplete="new-password" required[!s.github_has_token];
                div.row { button type="submit" { "Save and test" } }
            }
        }
        div.card {
            h2 { "Trackers" }
            p.muted {
                "Lets users link Trakt or Simkl in the app, so what they watch is scrobbled there. Register Couchmates once on each "
                "site and paste its keys here; leave a service blank to turn it off. "
                "Trakt: trakt.tv/oauth/applications → New application, redirect URI urn:ietf:wg:oauth:2.0:oob. "
                "Simkl: simkl.com/settings/developer → Create new app."
            }
            form method="post" action="/settings/trackers" {
                label for="trakt_id" { "Trakt client ID" }
                input #trakt_id type="text" name="trakt_client_id" autocomplete="off" value=[s.trakt_client_id];
                label for="trakt_secret" { "Trakt client secret" @if s.trakt_has_secret { " (leave blank to keep the saved one)" } }
                input #trakt_secret type="password" name="trakt_client_secret" autocomplete="new-password";
                label for="simkl_id" { "Simkl client ID" }
                input #simkl_id type="text" name="simkl_client_id" autocomplete="off" value=[s.simkl_client_id];
                div.row { button type="submit" { "Save" } }
            }
        }
        div.card {
            h2 { "Cast photos (TMDB)" }
            p.muted {
                "Optional. With a free TMDB key the app shows actors with photos and roles on each title, like Plezy did. "
                "Without one it shows the catalog's names. Get a key at themoviedb.org → Settings → API "
                "(the API key or the read access token both work)."
            }
            form method="post" action="/settings/tmdb" {
                label for="tmdb_key" { "TMDB key" @if s.tmdb_has_key { " (saved; leave blank to keep it, or type 'remove')" } }
                input #tmdb_key type="password" name="key" autocomplete="new-password";
                div.row { button type="submit" { "Save and test" } }
            }
        }
        div.card {
            h2 { "Tracearr" }
            p.muted {
                "Optional. The Hub can answer like a Jellyfin server, so Tracearr can follow who watches what, from "
                "where and on which device. In Tracearr, add a Jellyfin server with the address below and this key. "
                "Everyone shows up there, including people who turned off sharing what they watch with friends. "
                "There's no library, and Tracearr can't stop streams or send messages."
            }
            p { "Server address: " b { (s.hub) "/jellyfin" } }
            @if let Some(key) = s.tracearr_new_key {
                div.flash.ok {
                    "Your API key. Copy it now: the Hub keeps only a fingerprint and can't show it again."
                    div { span.code style="font-size:15px;letter-spacing:0;word-break:break-all" { (key) } }
                }
            }
            div.row {
                @if s.tracearr_has_key { span.pill.ok { "Key set" } } @else { span.pill { "No key" } }
                form.inline method="post" action="/settings/tracearr/key" {
                    button.secondary type="submit" { @if s.tracearr_has_key { "Replace key" } @else { "Make a key" } }
                }
                @if s.tracearr_has_key {
                    form.inline method="post" action="/settings/tracearr/revoke" {
                        button.secondary type="submit" { "Turn off" }
                    }
                }
            }
        }
        div.card {
            h2 { "Chat" }
            p.muted {
                "Words to star out in chat messages, one per line or separated by commas. They match whole words "
                "in any case, so blocking \"ass\" leaves \"class\" alone. Chat admins are set on each user's page; "
                "everyone else can send at most 5 messages in 10 seconds."
            }
            form method="post" action="/settings/chat" {
                label for="chat_words" { "Blocked words" }
                textarea #chat_words name="words" rows="4" spellcheck="false" { (s.chat_blocked_words.unwrap_or("")) }
                div.row { button type="submit" { "Save" } }
            }
        }
        div.card {
            h2 { "For the app" }
            p { "Hub address to enter in Couchmates: " b { (s.hub) } }
        }
        div.card {
            h2 { "Two-factor sign-in" }
            p { span.pill.ok { "On" } " Signing in to this dashboard needs the admin password and a code from your authenticator app." }
            form method="post" action="/settings/2fa/reset" {
                label for="reset_code" { "To move it to another phone, enter a current code, then scan the new QR code" }
                input #reset_code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" required;
                div.row { button.secondary type="submit" { "Set up again" } }
            }
        }
    };
    layout("Settings", "/settings", flash, body)
}
