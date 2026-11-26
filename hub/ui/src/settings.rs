//! The settings page: Telegram-Stremio, LiveKit, the voice relay, the Hub address and 2FA.
//!
//! Two panes: the sections listed on the left, grouped, each with a status
//! dot; the chosen section on the right. The chosen one is the URL's
//! `#fragment` (CSS `:target`), and every form posts to `…#its-section`, so the
//! page that comes back after saving opens on the same section.

use maud::{Markup, PreEscaped, html};

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

/// How a section stands, for its dot and its badge.
#[derive(Clone, Copy, PartialEq)]
enum State {
    Ok,
    Warn,
    Off,
    /// Nothing to report (the Hub address).
    None,
}

struct Section {
    id: &'static str,
    title: &'static str,
    state: State,
    status: String,
}

fn has(v: Option<&str>) -> bool {
    v.is_some_and(|s| !s.trim().is_empty())
}

fn sections(s: &Settings) -> Vec<(&'static str, Vec<Section>)> {
    let sec = |id, title, state, status: &str| Section { id, title, state, status: status.to_string() };
    let tgs = if s.tgs_hide_catalog == Some(true) {
        sec("telegram-stremio", "Telegram-Stremio", State::Warn, "Hide Catalog is on")
    } else if has(s.tgs_url) && s.tgs_has_password {
        sec("telegram-stremio", "Telegram-Stremio", State::Ok, "Connected")
    } else {
        sec("telegram-stremio", "Telegram-Stremio", State::Off, "Not set up")
    };
    let updates = if has(s.github_repo) && s.github_has_token {
        sec("app-updates", "App updates", State::Ok, "Connected")
    } else {
        sec("app-updates", "App updates", State::Off, "Not set up")
    };
    let livekit = if has(s.livekit_url) && has(s.livekit_key) && s.livekit_has_secret {
        let status = if s.voice_mode == "direct" { "Saved, not in use" } else { "In use" };
        sec("livekit", "LiveKit", if s.voice_mode == "direct" { State::Off } else { State::Ok }, status)
    } else {
        sec("livekit", "LiveKit", State::Off, "Not set up")
    };
    let relay = match (s.voice_mode == "direct", has(s.turn_server)) {
        (true, true) => sec("voice-relay", "Voice relay", State::Ok, "Direct voice on"),
        (true, false) => sec("voice-relay", "Voice relay", State::Warn, "Direct voice on, no relay saved"),
        (false, true) => sec("voice-relay", "Voice relay", State::Off, "Saved, LiveKit in use"),
        (false, false) => sec("voice-relay", "Voice relay", State::Off, "Off"),
    };
    let trackers: Vec<&str> = [(has(s.trakt_client_id), "Trakt"), (has(s.simkl_client_id), "Simkl")]
        .into_iter()
        .filter_map(|(on, name)| on.then_some(name))
        .collect();
    let trackers = if trackers.is_empty() {
        sec("trackers", "Trackers", State::Off, "Off")
    } else {
        sec("trackers", "Trackers", State::Ok, &format!("{} on", trackers.join(" and ")))
    };
    let tmdb = if s.tmdb_has_key {
        sec("cast-photos", "Cast photos", State::Ok, "On")
    } else {
        sec("cast-photos", "Cast photos", State::Off, "Off")
    };
    let tracearr = if s.tracearr_has_key {
        sec("tracearr", "Tracearr", State::Ok, "Key set")
    } else {
        sec("tracearr", "Tracearr", State::Off, "Off")
    };
    let words =
        s.chat_blocked_words.unwrap_or("").split(|c| c == ',' || c == '\n').filter(|w| !w.trim().is_empty()).count();
    let chat = match words {
        0 => sec("chat", "Chat", State::Off, "No blocked words"),
        1 => sec("chat", "Chat", State::Ok, "1 blocked word"),
        n => sec("chat", "Chat", State::Ok, &format!("{n} blocked words")),
    };
    vec![
        ("Server", vec![tgs, sec("app-address", "App address", State::None, ""), updates]),
        ("Voice", vec![livekit, relay]),
        ("Integrations", vec![trackers, tmdb, tracearr]),
        ("Community", vec![chat]),
        ("Security", vec![sec("two-factor", "Two-factor sign-in", State::Ok, "On")]),
    ]
}

fn badge(section: &Section) -> Markup {
    html! {
        @match section.state {
            State::Ok => span.pill.ok { (section.status) },
            State::Warn => span.pill.warn { (section.status) },
            State::Off => span.pill { (section.status) },
            State::None => {},
        }
    }
}

/// Highlights the open section's link. One pair of rules per section, since
/// CSS can't compare an id with an href.
fn nav_css(ids: &[&str]) -> String {
    let mut css = String::new();
    for (i, id) in ids.iter().enumerate() {
        css.push_str(&format!(".settings:has(#{id}:target) a[href=\"#{id}\"]"));
        if i == 0 {
            css.push_str(&format!(",.settings:not(:has(.set-section:target)) a[href=\"#{id}\"]"));
        }
        css.push_str("{background:var(--accent-soft);color:var(--text)}");
    }
    css
}

/// "Saved. Leave blank to keep it." under a secret's field.
fn keep_hint(saved: bool, removable: bool) -> Markup {
    html! {
        @if saved {
            div.hint {
                "Saved. Leave blank to keep it" @if removable { ", or type " code { "remove" } " to delete it" } "."
            }
        }
    }
}

fn section(sec: &Section, desc: Markup, body: Markup) -> Markup {
    html! {
        section.set-section #(sec.id) aria-labelledby=(format!("{}-title", sec.id)) {
            div.set-head {
                h2 #(format!("{}-title", sec.id)) { (sec.title) }
                (badge(sec))
            }
            div.set-desc { (desc) }
            (body)
        }
    }
}

pub fn page(s: &Settings, flash: Option<&Flash>) -> Markup {
    let groups = sections(s);
    let find = |id: &str| groups.iter().flat_map(|(_, list)| list).find(|x| x.id == id).expect("known section");
    let ids: Vec<&str> = groups.iter().flat_map(|(_, list)| list.iter().map(|x| x.id)).collect();

    let tgs = section(
        find("telegram-stremio"),
        html! { p { "Your server's public address and its web panel admin login. The Hub signs in like the panel does to manage access tokens and read stats." } },
        html! {
            @if s.tgs_hide_catalog == Some(true) {
                div.flash.bad {
                    p { "\"Hide Catalog\" is on in Telegram-Stremio, so the app can't show any rows. Despite its description it "
                    "hides catalogs from every token, including your users'. Streams still need each user's token." }
                    form.inline method="post" action="/settings/tgs/show-catalog#telegram-stremio" {
                        button type="submit" { "Turn off Hide Catalog" }
                    }
                }
            }
            form method="post" action="/settings/tgs#telegram-stremio" {
                label for="tgs_url" { "Server address" }
                input #tgs_url type="url" name="url" required placeholder="https://tg.example.com" value=[s.tgs_url];
                label for="tgs_username" { "Admin username" }
                input #tgs_username type="text" name="username" required autocomplete="off" value=[s.tgs_username];
                label for="tgs_password" { "Admin password" }
                input #tgs_password type="password" name="password" autocomplete="new-password" required[!s.tgs_has_password];
                (keep_hint(s.tgs_has_password, false))
                div.actions { button type="submit" { "Save and test" } }
            }
        },
    );

    let app_address = section(
        find("app-address"),
        html! { p { "The address people enter when they first open Couchmates. Their username and password come from the Users page." } },
        html! {
            label { "Hub address" }
            div.address { (s.hub) }
        },
    );

    let updates = section(
        find("app-updates"),
        html! {
            p {
                "Apps check here for new versions. The Hub reads the newest versioned release (not the \"Latest build\" pre-release) "
                "from the private GitHub repo and gives signed-in apps a short-lived download link."
            }
            p {
                "Make a fine-grained token on GitHub (Settings → Developer settings → Fine-grained tokens) with access to just "
                "this repo and Contents: Read-only."
            }
        },
        html! {
            form method="post" action="/settings/updates#app-updates" {
                label for="gh_repo" { "Repository" }
                input #gh_repo type="text" name="repo" required placeholder="AetherVoyager/couchmates" value=[s.github_repo];
                label for="gh_token" { "GitHub token" }
                input #gh_token type="password" name="token" autocomplete="new-password" required[!s.github_has_token];
                (keep_hint(s.github_has_token, false))
                div.actions { button type="submit" { "Save and test" } }
            }
        },
    );

    let livekit = section(
        find("livekit"),
        html! { p { "From LiveKit Cloud (Settings → API keys) or your own server. The secret stays on the Hub; apps get short-lived voice tokens from it." } },
        html! {
            form method="post" action="/settings/livekit#livekit" {
                label for="lk_url" { "Server URL" }
                input #lk_url type="text" name="url" required placeholder="wss://your-project.livekit.cloud" value=[s.livekit_url];
                label for="lk_key" { "API key" }
                input #lk_key type="text" name="key" required autocomplete="off" value=[s.livekit_key];
                label for="lk_secret" { "API secret" }
                input #lk_secret type="password" name="secret" autocomplete="new-password" required[!s.livekit_has_secret];
                (keep_hint(s.livekit_has_secret, false))
                div.actions { button type="submit" { "Save and test" } }
            }
        },
    );

    let relay = section(
        find("voice-relay"),
        html! {
            p {
                "Optional. Your own TURN server (coturn), for direct voice: the apps in a watch party talk to each other "
                "peer to peer, and go through this relay when they can't reach each other (mobile data, shared NAT). "
                "The login stays on the Hub; apps get it only while signed in."
            }
        },
        html! {
            form method="post" action="/settings/voice#voice-relay" {
                div.part style="margin-top:20px" {
                    h3 { "Voice chat uses" }
                    div.choices role="radiogroup" {
                        label.choice {
                            input type="radio" name="mode" value="livekit" checked[s.voice_mode != "direct"];
                            span { b { "LiveKit" } span { "Your LiveKit server carries everyone's audio." } }
                        }
                        label.choice {
                            input type="radio" name="mode" value="direct" checked[s.voice_mode == "direct"];
                            span { b { "Direct, through this relay" } span { "Peer to peer, with the relay as a fallback." } }
                        }
                    }
                    p.hint {
                        "Apps pick up a switch the next time they join voice. Direct voice suits a few people at a time, "
                        "and needs the app version that added it on every device."
                    }
                }
                div.part {
                    h3 { "Relay" }
                    label for="turn_server" { "Relay address" }
                    input #turn_server type="text" name="server" placeholder="203.0.113.5:3478" value=[s.turn_server];
                }
                div.part {
                    h3 { "Login" }
                    p.hint {
                        "With a shared secret (coturn's use-auth-secret and static-auth-secret) each app gets a login that "
                        "expires after 6 hours. Otherwise enter a fixed username and password from the relay's turnserver.conf."
                    }
                    label for="turn_secret" { "Shared secret" }
                    input #turn_secret type="password" name="secret" autocomplete="new-password";
                    (keep_hint(s.turn_has_secret, true))
                    div.form-grid {
                        div {
                            label for="turn_user" { "Or a fixed username" }
                            input #turn_user type="text" name="username" autocomplete="off" value=[s.turn_username];
                        }
                        div {
                            label for="turn_pass" { "and its password" }
                            input #turn_pass type="password" name="password" autocomplete="new-password";
                            (keep_hint(s.turn_has_password, false))
                        }
                    }
                }
                div.actions { button type="submit" { "Save" } }
            }
        },
    );

    let trackers = section(
        find("trackers"),
        html! {
            p {
                "Lets users link Trakt or Simkl in the app, so what they watch is scrobbled there. Register Couchmates once on each "
                "site and paste its keys here; leave a service blank to turn it off."
            }
            ul.steps {
                li { "Trakt: trakt.tv/oauth/applications → New application, redirect URI " code { "urn:ietf:wg:oauth:2.0:oob" } }
                li { "Simkl: simkl.com/settings/developer → Create new app" }
            }
        },
        html! {
            form method="post" action="/settings/trackers#trackers" {
                div.part style="margin-top:20px" {
                    h3 { "Trakt" }
                    div.form-grid {
                        div {
                            label for="trakt_id" { "Client ID" }
                            input #trakt_id type="text" name="trakt_client_id" autocomplete="off" value=[s.trakt_client_id];
                        }
                        div {
                            label for="trakt_secret" { "Client secret" }
                            input #trakt_secret type="password" name="trakt_client_secret" autocomplete="new-password";
                            (keep_hint(s.trakt_has_secret, false))
                        }
                    }
                }
                div.part {
                    h3 { "Simkl" }
                    label for="simkl_id" { "Client ID" }
                    input #simkl_id type="text" name="simkl_client_id" autocomplete="off" value=[s.simkl_client_id];
                }
                div.actions { button type="submit" { "Save" } }
            }
        },
    );

    let tmdb = section(
        find("cast-photos"),
        html! {
            p {
                "Optional. With a free TMDB key the app shows actors with photos and roles on each title. "
                "Without one it shows the catalog's names. Get a key at themoviedb.org → Settings → API "
                "(the API key or the read access token both work)."
            }
        },
        html! {
            form method="post" action="/settings/tmdb#cast-photos" {
                label for="tmdb_key" { "TMDB key" }
                input #tmdb_key type="password" name="key" autocomplete="new-password";
                (keep_hint(s.tmdb_has_key, true))
                div.actions { button type="submit" { "Save and test" } }
            }
        },
    );

    let tracearr = section(
        find("tracearr"),
        html! {
            p {
                "Optional. The Hub can answer like a Jellyfin server, so Tracearr can follow who watches what, from "
                "where and on which device. In Tracearr, add a Jellyfin server with the address below and this key."
            }
            p {
                "Everyone shows up there, including people who turned off sharing what they watch with friends. "
                "There's no library, and Tracearr can't stop streams or send messages."
            }
        },
        html! {
            label { "Server address" }
            div.address { (s.hub) "/jellyfin" }
            @if let Some(key) = s.tracearr_new_key {
                div.flash.ok style="margin-top:20px" {
                    p { "Your API key. Copy it now: the Hub keeps only a fingerprint and can't show it again." }
                    div { span.code style="font-size:14px;letter-spacing:0;word-break:break-all;user-select:all" { (key) } }
                }
            }
            div.actions {
                form.inline method="post" action="/settings/tracearr/key#tracearr" {
                    button type="submit" { @if s.tracearr_has_key { "Replace key" } @else { "Make a key" } }
                }
                @if s.tracearr_has_key {
                    form.inline method="post" action="/settings/tracearr/revoke#tracearr" {
                        button.secondary type="submit" { "Turn off" }
                    }
                }
            }
        },
    );

    let chat = section(
        find("chat"),
        html! {
            p {
                "Words to star out in chat messages, one per line or separated by commas. They match whole words "
                "in any case, so blocking \"ass\" leaves \"class\" alone."
            }
            p { "Chat admins are set on each user's page; everyone else can send at most 5 messages in 10 seconds." }
        },
        html! {
            form method="post" action="/settings/chat#chat" {
                label for="chat_words" { "Blocked words" }
                textarea #chat_words name="words" rows="6" spellcheck="false" { (s.chat_blocked_words.unwrap_or("")) }
                div.actions { button type="submit" { "Save" } }
            }
        },
    );

    let two_factor = section(
        find("two-factor"),
        html! { p { "Signing in to this dashboard needs the admin password and a code from your authenticator app." } },
        html! {
            form method="post" action="/settings/2fa/reset#two-factor" {
                div.part style="margin-top:20px" {
                    h3 { "Move to another phone" }
                    p.hint { "Enter a current code, then scan the new QR code on the next page." }
                    label for="reset_code" { "Current code" }
                    input #reset_code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" required style="max-width:200px";
                }
                div.actions { button.secondary type="submit" { "Set up again" } }
            }
        },
    );

    let body = html! {
        h1 { "Settings" }
        style { (PreEscaped(nav_css(&ids))) }
        div.settings {
            nav.settings-nav aria-label="Settings sections" {
                @for (group, list) in &groups {
                    div.group { (group) }
                    @for sec in list {
                        a href=(format!("#{}", sec.id)) {
                            (sec.title)
                            @match sec.state {
                                State::Ok => span.dot.ok title=(sec.status) {},
                                State::Warn => span.dot.warn title=(sec.status) {},
                                State::Off => span.dot title=(sec.status) {},
                                State::None => span.dot.none {},
                            }
                        }
                    }
                }
            }
            div.settings-pane {
                (tgs) (app_address) (updates) (livekit) (relay) (trackers) (tmdb) (tracearr) (chat) (two_factor)
            }
        }
    };
    layout("Settings", "/settings", flash, body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Settings<'static> {
        Settings {
            tgs_url: Some("https://tg.example.com"),
            tgs_username: Some("admin"),
            tgs_has_password: true,
            tgs_hide_catalog: Some(false),
            livekit_url: None,
            livekit_key: None,
            livekit_has_secret: false,
            voice_mode: "direct",
            turn_server: Some("203.0.113.5:3478"),
            turn_has_secret: true,
            turn_username: None,
            turn_has_password: false,
            github_repo: None,
            github_has_token: false,
            trakt_client_id: Some("abc"),
            trakt_has_secret: true,
            simkl_client_id: None,
            tmdb_has_key: false,
            tracearr_has_key: false,
            tracearr_new_key: None,
            chat_blocked_words: Some("foo, bar\nbaz"),
            hub: "https://hub.example.com",
        }
    }

    #[test]
    fn every_form_returns_to_its_section() {
        let html = page(&sample(), None).into_string();
        for (action, id) in [
            ("/settings/tgs", "telegram-stremio"),
            ("/settings/updates", "app-updates"),
            ("/settings/livekit", "livekit"),
            ("/settings/voice", "voice-relay"),
            ("/settings/trackers", "trackers"),
            ("/settings/tmdb", "cast-photos"),
            ("/settings/tracearr/key", "tracearr"),
            ("/settings/chat", "chat"),
            ("/settings/2fa/reset", "two-factor"),
        ] {
            assert!(html.contains(&format!("action=\"{action}#{id}\"")), "{action}");
            assert!(html.contains(&format!("id=\"{id}\"")), "{id}");
            assert!(html.contains(&format!("href=\"#{id}\"")), "{id} link");
        }
    }

    #[test]
    fn statuses_follow_the_settings() {
        let html = page(&sample(), None).into_string();
        assert!(html.contains("Direct voice on"));
        assert!(html.contains("Trakt on"));
        assert!(html.contains("3 blocked words"));
        assert!(html.contains("value=\"direct\" checked"));
    }
}
