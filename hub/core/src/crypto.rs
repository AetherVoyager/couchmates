//! Randomness, hashing, encryption of stored secrets, and JWT signing.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut buf = [0u8; N];
    getrandom::fill(&mut buf).expect("crypto.getRandomValues is available in Workers");
    buf
}

/// A random URL-safe token, for sessions and device sign-ins.
pub fn random_token() -> String {
    URL_SAFE_NO_PAD.encode(random_bytes::<32>())
}

/// A short random id for database rows.
pub fn random_id() -> String {
    hex::encode(random_bytes::<8>())
}

pub fn sha256_hex(input: &str) -> String {
    hex::encode(Sha256::digest(input.as_bytes()))
}

/// Equality that doesn't stop at the first differing byte.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Checks a typed password against the expected one without leaking where
/// they differ (both are hashed first, so lengths don't leak either).
pub fn password_matches(input: &str, expected: &str) -> bool {
    constant_time_eq(&Sha256::digest(input.as_bytes()), &Sha256::digest(expected.as_bytes()))
}

/// Encrypts small secrets (passwords, API secrets, tokens) for storage in D1.
pub struct Sealer {
    cipher: Aes256Gcm,
}

impl Sealer {
    pub fn new(hub_secret: &str) -> Self {
        let key_bytes = Sha256::digest(format!("couchmates-hub:settings:{hub_secret}").as_bytes());
        let key = Key::<Aes256Gcm>::try_from(key_bytes.as_slice()).expect("32-byte key");
        Self { cipher: Aes256Gcm::new(&key) }
    }

    pub fn seal(&self, plaintext: &str) -> String {
        let nonce_bytes = random_bytes::<12>();
        let nonce = Nonce::try_from(nonce_bytes.as_slice()).expect("12-byte nonce");
        let ciphertext = self
            .cipher
            .encrypt(&nonce, plaintext.as_bytes())
            .expect("AES-GCM encryption does not fail for small inputs");
        let mut out = nonce_bytes.to_vec();
        out.extend(ciphertext);
        STANDARD.encode(out)
    }

    pub fn open(&self, sealed: &str) -> Option<String> {
        let bytes = STANDARD.decode(sealed).ok()?;
        if bytes.len() < 12 {
            return None;
        }
        let (nonce_bytes, ciphertext) = bytes.split_at(12);
        let nonce = Nonce::try_from(nonce_bytes).ok()?;
        let plaintext = self.cipher.decrypt(&nonce, ciphertext).ok()?;
        String::from_utf8(plaintext).ok()
    }
}

/// An HS256 JWT over [claims].
pub fn sign_jwt(secret: &str, claims: &serde_json::Value) -> String {
    let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let payload = URL_SAFE_NO_PAD.encode(claims.to_string());
    let signing_input = format!("{header}.{payload}");
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(signing_input.as_bytes());
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    format!("{signing_input}.{signature}")
}

/// The claims of an HS256 [token] signed with [secret]; None when the signature, `nbf` or `exp` is wrong.
pub fn verify_jwt(secret: &str, token: &str, now: i64) -> Option<serde_json::Value> {
    let mut parts = token.trim().split('.');
    let (header, payload, signature) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let head: serde_json::Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(header).ok()?).ok()?;
    if head.get("alg").and_then(serde_json::Value::as_str) != Some("HS256") {
        return None;
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(format!("{header}.{payload}").as_bytes());
    mac.verify_slice(&URL_SAFE_NO_PAD.decode(signature).ok()?).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()?;
    let at = |k: &str| claims.get(k).and_then(serde_json::Value::as_i64);
    // A minute of slack for clock drift.
    if at("nbf").is_some_and(|nbf| nbf > now + 60) || at("exp").is_some_and(|exp| exp < now - 60) {
        return None;
    }
    Some(claims)
}

/// Base64 (standard) of the SHA-256 of [bytes], as LiveKit puts in its webhook tokens.
pub fn sha256_base64(bytes: &[u8]) -> String {
    STANDARD.encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jwts_verify_with_the_right_secret_only() {
        let token = sign_jwt("s3", &serde_json::json!({"iss": "key", "exp": 2_000, "nbf": 1_000}));
        assert_eq!(verify_jwt("s3", &token, 1_500).unwrap()["iss"], "key");
        assert!(verify_jwt("other", &token, 1_500).is_none());
        assert!(verify_jwt("s3", &token, 3_000).is_none());
        assert!(verify_jwt("s3", &token, 500).is_none());
        assert!(verify_jwt("s3", &format!("{token}x"), 1_500).is_none());
        assert!(verify_jwt("s3", "a.b", 1_500).is_none());
    }

    #[test]
    fn sealer_round_trips_and_rejects_tampering() {
        let sealer = Sealer::new("test-secret");
        let sealed = sealer.seal("hunter2");
        assert_ne!(sealed, "hunter2");
        assert_eq!(sealer.open(&sealed).as_deref(), Some("hunter2"));
        assert_eq!(Sealer::new("other").open(&sealed), None);
        let mut bytes = STANDARD.decode(&sealed).unwrap();
        *bytes.last_mut().unwrap() ^= 1;
        assert_eq!(sealer.open(&STANDARD.encode(bytes)), None);
    }

    #[test]
    fn jwt_matches_known_signature() {
        let claims = serde_json::json!({"sub": "a"});
        let token = sign_jwt("secret", &claims);
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        let mut mac = Hmac::<Sha256>::new_from_slice(b"secret").unwrap();
        mac.update(format!("{}.{}", parts[0], parts[1]).as_bytes());
        mac.verify_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
    }

    #[test]
    fn password_compare() {
        assert!(password_matches("abc", "abc"));
        assert!(!password_matches("abc", "abd"));
        assert!(!password_matches("", "abc"));
    }
}
