//! The admin sign-in page and two-factor setup.

use maud::{DOCTYPE, Markup, PreEscaped, html};

use crate::layout::{CSS, bare};

pub fn login(error: Option<&str>) -> Markup {
    html! {
        (DOCTYPE)
        html lang="en" {
            head {
                meta charset="utf-8";
                meta name="viewport" content="width=device-width, initial-scale=1";
                title { "Sign in · Couchmates Hub" }
                style { (PreEscaped(CSS)) }
            }
            body {
                div.login {
                    h1 { "Couchmates Hub" }
                    @if let Some(e) = error { div.flash.bad { (e) } }
                    div.card {
                        form method="post" action="/login" {
                            label for="password" { "Admin password" }
                            input #password type="password" name="password" autocomplete="current-password" required autofocus;
                            label for="code" { "Authenticator code" }
                            input #code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123456";
                            p.muted { "Signing in for the first time? Leave the code empty and you'll set it up next." }
                            div.row { button type="submit" { "Sign in" } }
                        }
                    }
                }
            }
        }
    }
}

/// [qr_svg] encodes the `otpauth://` link; [grouped_key] is the same secret
/// in groups of four for typing in by hand.
pub fn setup_2fa(qr_svg: &str, grouped_key: &str, error: Option<&str>) -> Markup {
    bare(
        "Set up two-factor sign-in",
        html! {
            h1 { "Set up two-factor sign-in" }
            @if let Some(e) = error { div.flash.bad { (e) } }
            div.card {
                p { "Scan this with an authenticator app (Google Authenticator, Microsoft Authenticator, 1Password, Bitwarden, Aegis and so on). From now on, signing in needs the password and the app's 6-digit code." }
                div.qr { (PreEscaped(qr_svg)) }
                p.muted { "Can't scan? Enter this key by hand: " code { (grouped_key) } }
                form method="post" action="/setup-2fa" {
                    label for="code" { "Code from the app" }
                    input #code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" required autofocus;
                    div.row { button type="submit" { "Turn on" } }
                }
            }
            form.inline method="post" action="/logout" { button.secondary type="submit" { "Sign out" } }
        },
    )
}
