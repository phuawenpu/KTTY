//! WASM bindings around `ktty-common`'s crypto, exposed to the Flutter
//! PWA via `wasm-bindgen`. Build with:
//!
//!     wasm-pack build --release --target web --out-dir ../../web/wasm
//!
//! The output JS module gets imported from `web/index.html` and stamped
//! onto `window._kttyCrypto`. The Flutter web side
//! (`lib/services/crypto/native_crypto_web.dart`) then calls into it
//! through `package:web` JS interop.
//!
//! Function names use camelCase via `js_name = ...` so they match the
//! existing Dart-side bindings without churn.

use ktty_common::crypto;
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = deriveKey)]
pub fn derive_key(pin: &str) -> Result<Vec<u8>, JsError> {
    crypto::derive_key(pin)
        .map(|k| k.to_vec())
        .map_err(|e| JsError::new(&e.to_string()))
}

#[wasm_bindgen(js_name = roomId)]
pub fn room_id(derived_key: &[u8]) -> Result<String, JsError> {
    let arr: [u8; 32] = derived_key
        .try_into()
        .map_err(|_| JsError::new("derived_key must be 32 bytes"))?;
    Ok(crypto::room_id(&arr))
}

#[wasm_bindgen]
pub fn encrypt(key: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, JsError> {
    let arr: [u8; 32] = key
        .try_into()
        .map_err(|_| JsError::new("key must be 32 bytes"))?;
    crypto::encrypt(&arr, plaintext).map_err(|e| JsError::new(&e.to_string()))
}

#[wasm_bindgen]
pub fn decrypt(key: &[u8], packed: &[u8]) -> Result<Vec<u8>, JsError> {
    let arr: [u8; 32] = key
        .try_into()
        .map_err(|_| JsError::new("key must be 32 bytes"))?;
    crypto::decrypt(&arr, packed).map_err(|e| JsError::new(&e.to_string()))
}

/// Returns `ciphertext (1088 bytes) || shared_secret (32 bytes)` concatenated.
/// The Dart caller splits the last 32 bytes off as the shared secret.
#[wasm_bindgen(js_name = mlkemEncapsulate)]
pub fn mlkem_encapsulate(ek_bytes: &[u8]) -> Result<Vec<u8>, JsError> {
    let (ct, ss) = crypto::mlkem_encapsulate(ek_bytes)
        .map_err(|e| JsError::new(&e.to_string()))?;
    let mut combined = Vec::with_capacity(ct.len() + 32);
    combined.extend_from_slice(&ct);
    combined.extend_from_slice(&ss);
    Ok(combined)
}

#[wasm_bindgen(js_name = computeHmac)]
pub fn compute_hmac(argon2_key: &[u8], data: &[u8]) -> Result<Vec<u8>, JsError> {
    let arr: [u8; 32] = argon2_key
        .try_into()
        .map_err(|_| JsError::new("argon2_key must be 32 bytes"))?;
    Ok(crypto::compute_hmac(&arr, data))
}

#[wasm_bindgen(js_name = verifyHmac)]
pub fn verify_hmac(argon2_key: &[u8], data: &[u8], expected: &[u8]) -> Result<bool, JsError> {
    let arr: [u8; 32] = argon2_key
        .try_into()
        .map_err(|_| JsError::new("argon2_key must be 32 bytes"))?;
    Ok(crypto::verify_hmac(&arr, data, expected))
}
