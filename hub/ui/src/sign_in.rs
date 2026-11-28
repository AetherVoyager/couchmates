//! The admin sign-in page and two-factor setup.

use maud::{Markup, PreEscaped, html};

use crate::layout::{bare, sign_in_frame};

/// What the sign-in form asks for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LoginForm {
    /// No authenticator yet: the admin password, then setup.
    Setup,
    /// The usual case: the authenticator code alone.
    Code,
    /// Too many wrong codes lately, from anywhere: the password and a code.
    Locked,
}

pub fn login(form: LoginForm, error: Option<&str>) -> Markup {
    let ask_password = form != LoginForm::Code;
    let ask_code = form != LoginForm::Setup;
    sign_in_frame(
        "Sign in",
        html! {
            h1 { "Sign in" }
            p.muted { "The admin dashboard for your Couchmates server." }
            @if let Some(e) = error { div.flash.bad role="alert" { (e) } }
            div.card {
                form method="post" action="/login" {
                    @if ask_password {
                        label for="password" { "Admin password" }
                        input #password type="password" name="password" autocomplete="current-password" required autofocus;
                    }
                    @if ask_code {
                        label for="code" { "Authenticator code" }
                        @if ask_password {
                            input #code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123456" required;
                        } @else {
                            input #code type="text" name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123456" required autofocus;
                        }
                    }
                    @match form {
                        LoginForm::Setup => p.hint { "First sign-in: you'll set up an authenticator app next." },
                        LoginForm::Code => p.hint { "The 6-digit code from your authenticator app." },
                        LoginForm::Locked => p.hint { "There were many wrong codes recently, so the admin password is needed too for now." },
                    }
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
                p { "Scan this with an authenticator app (Google Authenticator, Microsoft Authenticator, 1Password, Bitwarden, Aegis and so on). From now on, signing in needs only the app's 6-digit code." }
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
