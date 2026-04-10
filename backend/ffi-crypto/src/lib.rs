//! C ABI wrapper around `ktty-common`'s ML-KEM-768 encapsulation.
//!
//! Built as a `cdylib` and called from Flutter via `dart:ffi` on native
//! platforms (Android, iOS, desktop). The matching decapsulation runs in
//! the `ktty-agent` binary using the same `ml-kem` crate, which is what
//! makes the handshake actually interoperable.
//!
//! The only function exposed is `ktty_mlkem_encapsulate`. All other
//! crypto (Argon2id, XChaCha20-Poly1305, HMAC-SHA256) is handled by the
//! pure-Dart `cryptography` package, which is interoperable with Rust
//! since those algorithms are standardized and have no draft variants.

use ktty_common::crypto;

/// ML-KEM-768 encapsulate.
///
/// # Parameters
/// - `ek`: pointer to 1184 bytes of encapsulation key (the agent's ML-KEM public key)
/// - `ct_out`: pointer to a caller-allocated 1088-byte buffer for ciphertext
/// - `ss_out`: pointer to a caller-allocated 32-byte buffer for shared secret
///
/// # Returns
/// `0` on success, non-zero on error (invalid key length, encapsulation failure).
///
/// # Safety
/// - `ek` must point to at least 1184 readable bytes
/// - `ct_out` must point to at least 1088 writable bytes
/// - `ss_out` must point to at least 32 writable bytes
/// - All buffers must remain valid for the duration of the call
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ktty_mlkem_encapsulate(
    ek: *const u8,
    ct_out: *mut u8,
    ss_out: *mut u8,
) -> i32 {
    if ek.is_null() || ct_out.is_null() || ss_out.is_null() {
        return -1;
    }

    let ek_slice = unsafe { std::slice::from_raw_parts(ek, 1184) };

    match crypto::mlkem_encapsulate(ek_slice) {
        Ok((ct, ss)) => {
            if ct.len() != 1088 {
                return -3;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(ct.as_ptr(), ct_out, 1088);
                std::ptr::copy_nonoverlapping(ss.as_ptr(), ss_out, 32);
            }
            0
        }
        Err(_) => -2,
    }
}

/// Returns a non-zero value if the library was loaded successfully.
/// Used by the Flutter side to verify the dynamic library is reachable
/// before attempting any crypto calls.
#[unsafe(no_mangle)]
pub extern "C" fn ktty_ffi_crypto_version() -> u32 {
    1
}
