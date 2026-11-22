//! Admin two-factor codes (TOTP, RFC 6238) and app user password hashing
//! (PBKDF2-SHA256).

use base64::Engine;
use base64::engine::general_purpose::STANDARD_NO_PAD;
use hmac::{Hmac, KeyInit, Mac};
use sha1::Sha1;
#[cfg(not(target_arch = "wasm32"))]
use sha2::Sha256;

pub use couchmates_core::rules::{normalize_username, password_problem};

use crate::crypto::{constant_time_eq, random_bytes};

// -----------------------------------------------------------------------------
// TOTP

pub const TOTP_STEP_SECS: i64 = 30;
const BASE32: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn base32_encode(bytes: &[u8]) -> String {
    let mut out = String::new();
    let (mut buffer, mut bits) = (0u32, 0u32);
    for &b in bytes {
        buffer = (buffer << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            out.push(BASE32[((buffer >> (bits - 5)) & 31) as usize] as char);
            bits -= 5;
        }
    }
    if bits > 0 {
        out.push(BASE32[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    out
}

pub fn base32_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut buffer, mut bits) = (0u32, 0u32);
    for c in text.chars().filter(|c| !c.is_whitespace() && *c != '=') {
        let value = BASE32.iter().position(|&x| x as char == c.to_ascii_uppercase())? as u32;
        buffer = (buffer << 5) | value;
        bits += 5;
        if bits >= 8 {
            out.push((buffer >> (bits - 8)) as u8);
            bits -= 8;
        }
    }
    Some(out)
}

/// A new 160-bit TOTP secret, base32-encoded for authenticator apps.
pub fn new_totp_secret() -> String {
    base32_encode(&random_bytes::<20>())
}

/// The 6-digit code for [secret] at time step [step].
pub fn totp_code(secret: &[u8], step: i64) -> u32 {
    let mut mac = Hmac::<Sha1>::new_from_slice(secret).expect("HMAC takes any key length");
    mac.update(&(step as u64).to_be_bytes());
    let hash = mac.finalize().into_bytes();
    let offset = (hash[hash.len() - 1] & 0x0f) as usize;
    let binary = (u32::from(hash[offset] & 0x7f) << 24)
        | (u32::from(hash[offset + 1]) << 16)
        | (u32::from(hash[offset + 2]) << 8)
        | u32::from(hash[offset + 3]);
    binary % 1_000_000
}

/// The time step [code] is valid for, allowing one step of clock drift either
/// way, or None. The caller rejects steps at or before the last one used, so
/// a code can't be replayed.
pub fn verify_totp(secret_b32: &str, code: &str, now: i64) -> Option<i64> {
    let code: String = code.chars().filter(|c| !c.is_whitespace()).collect();
    if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let secret = base32_decode(secret_b32)?;
    let typed: u32 = code.parse().ok()?;
    let current = now.div_euclid(TOTP_STEP_SECS);
    (current - 1..=current + 1).find(|&step| {
        let expected = format!("{:06}", totp_code(&secret, step));
        constant_time_eq(expected.as_bytes(), format!("{typed:06}").as_bytes())
    })
}

/// The `otpauth://` link authenticator apps scan.
pub fn otpauth_uri(secret_b32: &str, account: &str) -> String {
    let issuer = "Couchmates Hub";
    let mut url = worker::Url::parse("otpauth://totp/").expect("static url");
    url.set_path(&format!("{issuer}:{account}"));
    url.query_pairs_mut()
        .append_pair("secret", secret_b32)
        .append_pair("issuer", issuer)
        .append_pair("algorithm", "SHA1")
        .append_pair("digits", "6")
        .append_pair("period", "30");
    url.to_string()
}

/// [text] as an inline SVG QR code.
pub fn qr_svg(text: &str) -> String {
    match qrcode::QrCode::new(text.as_bytes()) {
        Ok(code) => code
            .render::<qrcode::render::svg::Color>()
            .min_dimensions(220, 220)
            .dark_color(qrcode::render::svg::Color("#000000"))
            .light_color(qrcode::render::svg::Color("#ffffff"))
            .build(),
        Err(_) => String::new(),
    }
}

// -----------------------------------------------------------------------------
// Passwords

/// PBKDF2 rounds for new hashes. Stored in each hash, so it can change
/// without breaking existing passwords. Kept low so a sign-in fits the free
/// plan's 10 ms CPU limit (100k rounds measured 18-51 ms live).
pub const PASSWORD_ITERATIONS: u32 = 10_000;

#[cfg(target_arch = "wasm32")]
async fn pbkdf2(password: &[u8], salt: &[u8], iterations: u32) -> Result<Vec<u8>, String> {
    use wasm_bindgen::JsCast;
    let err = |e: wasm_bindgen::JsValue| format!("{e:?}");
    let global: web_sys::WorkerGlobalScope = js_sys::global().unchecked_into();
    let subtle = global.crypto().map_err(err)?.subtle();
    let usages = js_sys::Array::of1(&"deriveBits".into());
    let key_data = js_sys::Uint8Array::from(password);
    let key = wasm_bindgen_futures::JsFuture::from(
        subtle.import_key_with_str("raw", &key_data, "PBKDF2", false, &usages).map_err(err)?,
    )
    .await
    .map_err(err)?;
    let params = web_sys::Pbkdf2Params::new("PBKDF2", &"SHA-256".into(), iterations, &js_sys::Uint8Array::from(salt));
    let bits = wasm_bindgen_futures::JsFuture::from(
        subtle.derive_bits_with_object(&params, &key.unchecked_into(), 256).map_err(err)?,
    )
    .await
    .map_err(err)?;
    Ok(js_sys::Uint8Array::new(&bits).to_vec())
}

/// Plain-Rust PBKDF2-HMAC-SHA256 for native builds (tests).
#[cfg(not(target_arch = "wasm32"))]
async fn pbkdf2(password: &[u8], salt: &[u8], iterations: u32) -> Result<Vec<u8>, String> {
    let prf = Hmac::<Sha256>::new_from_slice(password).map_err(|e| e.to_string())?;
    let mut block = prf.clone();
    block.update(salt);
    block.update(&1u32.to_be_bytes());
    let mut u = block.finalize().into_bytes();
    let mut out = u;
    for _ in 1..iterations {
        let mut next = prf.clone();
        next.update(&u);
        u = next.finalize().into_bytes();
        for (o, x) in out.iter_mut().zip(u.iter()) {
            *o ^= x;
        }
    }
    Ok(out.to_vec())
}

/// `pbkdf2-sha256$<iterations>$<salt>$<hash>`.
pub async fn hash_password(password: &str) -> Result<String, String> {
    let salt = random_bytes::<16>();
    let hash = pbkdf2(password.as_bytes(), &salt, PASSWORD_ITERATIONS).await?;
    Ok(format!("pbkdf2-sha256${PASSWORD_ITERATIONS}${}${}", STANDARD_NO_PAD.encode(salt), STANDARD_NO_PAD.encode(hash)))
}

pub async fn verify_password(password: &str, stored: &str) -> bool {
    let parts: Vec<&str> = stored.split('$').collect();
    let [scheme, iterations, salt, hash] = parts.as_slice() else {
        return false;
    };
    let (Ok(iterations), Ok(salt), Ok(hash)) =
        (iterations.parse::<u32>(), STANDARD_NO_PAD.decode(salt), STANDARD_NO_PAD.decode(hash))
    else {
        return false;
    };
    if *scheme != "pbkdf2-sha256" || iterations == 0 || iterations > 2_000_000 {
        return false;
    }
    match pbkdf2(password.as_bytes(), &salt, iterations).await {
        Ok(computed) => constant_time_eq(&computed, &hash),
        Err(_) => false,
    }
}

/// A random password that's easy to read out: four groups of letters/digits.
pub fn generated_password() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let bytes = random_bytes::<16>();
    let chars: Vec<char> = bytes.iter().map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char).collect();
    chars.chunks(4).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("-")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        // The native futures here never wait, so one poll finishes them.
        let waker = std::task::Waker::noop();
        let mut cx = std::task::Context::from_waker(waker);
        let mut f = std::pin::pin!(f);
        match f.as_mut().poll(&mut cx) {
            std::task::Poll::Ready(v) => v,
            std::task::Poll::Pending => panic!("future didn't finish"),
        }
    }

    #[test]
    fn base32_round_trips() {
        assert_eq!(base32_encode(b"foobar"), "MZXW6YTBOI");
        assert_eq!(base32_decode("MZXW6YTBOI").unwrap(), b"foobar");
        assert_eq!(base32_decode("mzxw 6ytb oi====").unwrap(), b"foobar");
        assert!(base32_decode("1!").is_none());
        let secret = new_totp_secret();
        assert_eq!(secret.len(), 32);
        assert_eq!(base32_decode(&secret).unwrap().len(), 20);
    }

    #[test]
    fn totp_matches_rfc6238_vectors() {
        // RFC 6238 appendix B, SHA-1, last 6 digits.
        let secret = b"12345678901234567890";
        for (time, code) in
            [(59, 287082), (1111111109, 81804), (1111111111, 50471), (1234567890, 5924), (2000000000, 279037)]
        {
            assert_eq!(totp_code(secret, time / 30), code, "t={time}");
        }
        let b32 = base32_encode(secret);
        assert_eq!(verify_totp(&b32, "287082", 59), Some(1));
        assert_eq!(verify_totp(&b32, "287 082", 59 + 30), Some(1), "one step late is accepted");
        assert_eq!(verify_totp(&b32, "287082", 59 + 90), None, "three steps late is not");
        assert_eq!(verify_totp(&b32, "28708", 59), None);
        assert_eq!(verify_totp(&b32, "abcdef", 59), None);
    }

    #[test]
    fn otpauth_uri_is_scannable() {
        let uri = otpauth_uri("ABC", "admin");
        assert!(uri.starts_with("otpauth://totp/Couchmates%20Hub:admin?secret=ABC&issuer=Couchmates+Hub"));
        assert!(qr_svg(&uri).starts_with("<?xml") || qr_svg(&uri).starts_with("<svg"));
    }

    #[test]
    fn pbkdf2_matches_known_vector() {
        // RFC 7914 §11: PBKDF2-HMAC-SHA256("passwd", "salt", 1).
        let out = block_on(pbkdf2(b"passwd", b"salt", 1)).unwrap();
        assert_eq!(hex::encode(&out[..16]), "55ac046e56e3089fec1691c22544b605");
    }

    #[test]
    fn passwords_hash_and_verify() {
        let stored = block_on(hash_password("correct horse")).unwrap();
        assert!(stored.starts_with("pbkdf2-sha256$10000$"));
        assert!(block_on(verify_password("correct horse", &stored)));
        assert!(!block_on(verify_password("wrong horse", &stored)));
        assert!(!block_on(verify_password("correct horse", "garbage")));
        assert_ne!(stored, block_on(hash_password("correct horse")).unwrap(), "salted");
    }

    #[test]
    fn generated_passwords_are_readable_and_valid() {
        let p = generated_password();
        assert_eq!(p.len(), 19);
        assert!(password_problem(&p).is_none());
        assert_ne!(p, generated_password());
    }
}
