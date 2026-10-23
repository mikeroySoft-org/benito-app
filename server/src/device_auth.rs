//! Passwordless identity: per-device P-256 keys and hashed invite secrets.
//!
//! A device proves itself by signing `benito-device-auth:v1:<device_id>:<unix_ts>` with its
//! private key (Secure Enclave on iPhone). The server checks the ECDSA P-256 / SHA-256
//! signature (DER or raw r||s), that the timestamp is within [`MAX_CLOCK_SKEW_SECS`] of now, and
//! that it is newer than the last accepted one (replay guard), then mints a normal bearer session.
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use rand::RngCore;
use sha2::{Digest, Sha256};

/// How far a signed timestamp may drift from the server clock.
pub const MAX_CLOCK_SKEW_SECS: i64 = 300;

pub fn auth_message(device_id: &str, timestamp: i64) -> String {
    format!("benito-device-auth:v1:{device_id}:{timestamp}")
}

fn decode_b64(value: &str) -> Option<Vec<u8>> {
    let trimmed = value.trim();
    STANDARD
        .decode(trimmed)
        .or_else(|_| URL_SAFE_NO_PAD.decode(trimmed.trim_end_matches('=')))
        .ok()
}

/// Parses a base64 X9.63 (uncompressed or compressed) P-256 public key.
pub fn parse_public_key(b64: &str) -> Option<VerifyingKey> {
    let bytes = decode_b64(b64)?;
    VerifyingKey::from_sec1_bytes(&bytes).ok()
}

/// Canonical storage form of a public key (standard base64 of the uncompressed SEC1 point), so
/// the same key sent in different encodings maps to one `devices` row.
pub fn canonical_public_key(key: &VerifyingKey) -> String {
    STANDARD.encode(key.to_encoded_point(false).as_bytes())
}

pub fn verify(key: &VerifyingKey, message: &[u8], signature_b64: &str) -> bool {
    let Some(bytes) = decode_b64(signature_b64) else {
        return false;
    };
    let signature = Signature::from_der(&bytes).or_else(|_| Signature::from_slice(&bytes));
    match signature {
        Ok(sig) => key.verify(message, &sig).is_ok(),
        Err(_) => false,
    }
}

/// 32 random bytes, base64url without padding (goes inside invite links).
pub fn new_invite_secret() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn hash_secret(secret: &str) -> String {
    hex::encode(Sha256::digest(secret.trim().as_bytes()))
}

/// Constant-time comparison of two hex digests.
pub fn digests_match(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Passwordless accounts still need a unique `users.email` (NOT NULL UNIQUE in 001); the
/// reserved `.invalid` TLD can never collide with a real address or receive mail.
pub fn synthetic_email(user_id: &str) -> String {
    format!("{user_id}@device.benito.invalid")
}

/// Not a valid PHC string, so `verify_password` can never succeed for passwordless accounts.
pub const NO_PASSWORD_HASH: &str = "!passwordless";

pub fn is_synthetic_email(email: &str) -> bool {
    email.ends_with("@device.benito.invalid")
}
