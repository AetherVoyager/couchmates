//! The admin sign-in page and two-factor setup.

use maud::{Markup, PreEscaped, html};

use crate::layout::{bare, sign_in_frame};

pub fn login(error: Option<&str>) -> Markup {
    sign_in_frame(
        "Sign in",
        html! {
            h1 { "Sign in" }
            p.muted { "The admin dashboard for your Couchmates server." }
            @if let Some(e) = error { div.flash.bad role="alert" { (e) } }
            div.card {
                form method="post" action="/login" {
                    label for="password" { "Admin password" }
                    input #password type="password" name="password" autocomplete="current-password" required autofocus;
                    label for="code" { "Authenticator code" }
                    input #code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123456";
                    p.hint { "Signing in for the first time? Leave the code empty and you'll set it up next." }
                    div.row { button type="submit" style="width:100%;justify-content:center" { "Sign in" } }
                }
            }
        },
    )
}

/// [qr_svg] encodes the `otpauth://` link; [grouped_key] is the same secret
/// in groups of four for typing in by hand.
pub fn setup_2fa(qr_svg: &str, grouped_key: &str, error: Option<&str>) -> Markup {
    bare(
        "Set up two-factor sign-in",
        html! {
            h1 { "Set up two-factor sign-in" }
            p.muted { "One more step before the dashboard opens." }
            @if let Some(e) = error { div.flash.bad role="alert" { (e) } }
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
