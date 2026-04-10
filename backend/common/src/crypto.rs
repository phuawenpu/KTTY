use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    aead::{Aead, AeadCore, KeyInit, OsRng},
    XChaCha20Poly1305, XNonce,
};
use hmac::{Hmac, Mac};
use ml_kem::kem::Encapsulate;
use ml_kem::{EncodedSizeUser, KemCore, MlKem768};
use sha2::Sha256;
use thiserror::Error;

use crate::constants::*;

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("Argon2 error: {0}")]
    Argon2(String),
    #[error("Encryption error")]
    Encrypt,
    #[error("Decryption error")]
    Decrypt,
    #[error("Invalid packed data length")]
    InvalidLength,
    #[error("ML-KEM error")]
    MlKem,
}

/// Derive a 32-byte key from the user PIN using Argon2id.
/// Parameters must match Flutter's `PinUtils.deriveKey` exactly.
pub fn derive_key(pin: &str) -> Result<[u8; 32], CryptoError> {
    let params = Params::new(
        ARGON2_M_COST,
        ARGON2_T_COST,
        ARGON2_P_COST,
        Some(ARGON2_OUTPUT_LEN),
    )
    .map_err(|e| CryptoError::Argon2(e.to_string()))?;

    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut output = [0u8; 32];
    argon2
        .hash_password_into(pin.as_bytes(), STATIC_SALT, &mut output)
        .map_err(|e| CryptoError::Argon2(e.to_string()))?;

    Ok(output)
}

/// Generate Room ID as lowercase hex string from derived key.
pub fn room_id(derived_key: &[u8; 32]) -> String {
    hex::encode(derived_key)
}

/// Encrypt plaintext with XChaCha20-Poly1305.
/// Returns: nonce (24 bytes) || ciphertext || tag (16 bytes).
/// Must match Flutter's `CryptoService.encrypt` packing format.
pub fn encrypt(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let cipher =
        XChaCha20Poly1305::new_from_slice(key).map_err(|_| CryptoError::Encrypt)?;
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);

    // `encrypt` returns ciphertext with appended tag (ct || tag)
    let ct_with_tag = cipher
        .encrypt(&nonce, plaintext)
        .map_err(|_| CryptoError::Encrypt)?;

    // Pack: nonce (24) || ct || tag (16)
    let mut packed = Vec::with_capacity(NONCE_LEN + ct_with_tag.len());
    packed.extend_from_slice(&nonce);
    packed.extend_from_slice(&ct_with_tag);
    Ok(packed)
}

/// Decrypt packed data (nonce || ciphertext || tag).
/// Must match Flutter's `CryptoService.decrypt` unpacking format.
pub fn decrypt(key: &[u8; 32], packed: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if packed.len() < NONCE_LEN + MAC_LEN {
        return Err(CryptoError::InvalidLength);
    }

    let cipher =
        XChaCha20Poly1305::new_from_slice(key).map_err(|_| CryptoError::Decrypt)?;

    let nonce = XNonce::from_slice(&packed[..NONCE_LEN]);
    let ct_with_tag = &packed[NONCE_LEN..];

    cipher
        .decrypt(nonce, ct_with_tag)
        .map_err(|_| CryptoError::Decrypt)
}

/// Compute HMAC-SHA256 using the Argon2id-derived key.
pub fn compute_hmac(argon2_key: &[u8; 32], data: &[u8]) -> Vec<u8> {
    let mut mac =
        <Hmac<Sha256> as Mac>::new_from_slice(argon2_key).expect("HMAC accepts any key size");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// Verify HMAC with constant-time comparison.
pub fn verify_hmac(argon2_key: &[u8; 32], data: &[u8], expected: &[u8]) -> bool {
    let mut mac =
        <Hmac<Sha256> as Mac>::new_from_slice(argon2_key).expect("HMAC accepts any key size");
    mac.update(data);
    mac.verify_slice(expected).is_ok()
}

/// ML-KEM-768 encapsulation. Takes the agent's encapsulation (public) key and
/// returns `(ciphertext, shared_secret)`. The Flutter client side of the
/// handshake; the matching `decapsulate` lives in `agent::session`.
///
/// `ek_bytes` must be exactly 1184 bytes (ML-KEM-768 ek size).
/// Output ciphertext is 1088 bytes; shared secret is 32 bytes.
pub fn mlkem_encapsulate(ek_bytes: &[u8]) -> Result<(Vec<u8>, [u8; 32]), CryptoError> {
    type Ek = <MlKem768 as KemCore>::EncapsulationKey;
    let encoded: ml_kem::Encoded<Ek> =
        ek_bytes.try_into().map_err(|_| CryptoError::MlKem)?;
    let ek = Ek::from_bytes(&encoded);

    let mut rng = rand::thread_rng();
    let (ct, ss) = ek.encapsulate(&mut rng).map_err(|_| CryptoError::MlKem)?;

    let mut ss_arr = [0u8; 32];
    ss_arr.copy_from_slice(ss.as_slice());
    Ok((ct.as_slice().to_vec(), ss_arr))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_key_deterministic() {
        let key1 = derive_key("test1234").unwrap();
        let key2 = derive_key("test1234").unwrap();
        assert_eq!(key1, key2);
    }

    #[test]
    fn test_derive_key_different_pins() {
        let key1 = derive_key("pin1").unwrap();
        let key2 = derive_key("pin2").unwrap();
        assert_ne!(key1, key2);
    }

    #[test]
    fn test_room_id_hex() {
        let key = derive_key("test").unwrap();
        let rid = room_id(&key);
        assert_eq!(rid.len(), 64); // 32 bytes = 64 hex chars
        assert!(rid.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = [42u8; 32];
        let plaintext = b"Hello, KTTY!";
        let packed = encrypt(&key, plaintext).unwrap();
        let decrypted = decrypt(&key, &packed).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_packing_format() {
        let key = [42u8; 32];
        let plaintext = b"test";
        let packed = encrypt(&key, plaintext).unwrap();
        // nonce (24) + ciphertext (4) + tag (16) = 44
        assert_eq!(packed.len(), 24 + 4 + 16);
    }

    #[test]
    fn test_hmac_roundtrip() {
        let key = derive_key("mypin").unwrap();
        let data = b"shared secret bytes";
        let mac = compute_hmac(&key, data);
        assert!(verify_hmac(&key, data, &mac));
        assert!(!verify_hmac(&key, b"wrong data", &mac));
    }

    #[test]
    fn test_mlkem_encapsulate_roundtrip() {
        use ml_kem::kem::Decapsulate;
        let mut rng = rand::thread_rng();
        let (dk, ek) = MlKem768::generate(&mut rng);
        let ek_bytes = ek.as_bytes();

        let (ct_vec, ss_client) = mlkem_encapsulate(ek_bytes.as_slice()).unwrap();
        assert_eq!(ct_vec.len(), 1088);

        let ct: &ml_kem::Ciphertext<MlKem768> =
            ct_vec.as_slice().try_into().unwrap();
        let ss_server = dk.decapsulate(ct).unwrap();
        assert_eq!(ss_client.as_slice(), ss_server.as_slice());
    }
}
