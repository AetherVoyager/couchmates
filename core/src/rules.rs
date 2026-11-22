//! Rules both the Hub and the app apply. The app mirrors these in
//! `app/core/lib/src/rules.dart`, and `contract/rules.json` holds the cases
//! both sides test against.

pub const MIN_PASSWORD_LEN: usize = 8;
pub const MAX_PASSWORD_BYTES: usize = 256;

/// [input] as a username (lower case `a-z 0-9 . _ -`, 3–32 long), or None.
pub fn normalize_username(input: &str) -> Option<String> {
    let name = input.trim().to_ascii_lowercase();
    let ok = (3..=32).contains(&name.len())
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'));
    ok.then_some(name)
}

/// What's wrong with [password] as a new password, or None.
pub fn password_problem(password: &str) -> Option<String> {
    if password.chars().count() < MIN_PASSWORD_LEN {
        return Some(format!("Passwords need at least {MIN_PASSWORD_LEN} characters."));
    }
    if password.len() > MAX_PASSWORD_BYTES {
        return Some("That password is too long.".into());
    }
    None
}

/// The LiveKit room for a watch party room code: letters and digits only,
/// upper-cased, 4–16 long.
pub fn room_for_watch_code(code: &str) -> Option<String> {
    let code: String = code.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>().to_ascii_uppercase();
    (code.len() >= 4 && code.len() <= 16).then(|| format!("couchmates-{code}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn cases() -> Value {
        serde_json::from_str(include_str!("../contract/rules.json")).unwrap()
    }

    #[test]
    fn usernames_match_the_contract() {
        for case in cases()["usernames"].as_array().unwrap() {
            let input = case["input"].as_str().unwrap();
            assert_eq!(normalize_username(input).as_deref(), case["expect"].as_str(), "{input:?}");
        }
    }

    #[test]
    fn passwords_match_the_contract() {
        for case in cases()["passwords"].as_array().unwrap() {
            let input = case["input"].as_str().unwrap();
            assert_eq!(password_problem(input).is_none(), case["ok"].as_bool().unwrap(), "{input:?}");
        }
    }

    #[test]
    fn voice_rooms_match_the_contract() {
        for case in cases()["voice_rooms"].as_array().unwrap() {
            let input = case["input"].as_str().unwrap();
            assert_eq!(room_for_watch_code(input).as_deref(), case["expect"].as_str(), "{input:?}");
        }
    }
}
