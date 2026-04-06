/// Static salt agreed upon by Flutter and Rust teams.
/// Must match Flutter's `kStaticSalt` in `lib/services/crypto/pin_utils.dart`.
pub const STATIC_SALT: &[u8] = b"KTTY STATIC SALT VERSION 1";

/// Argon2id parameters — must match Flutter exactly.
pub const ARGON2_M_COST: u32 = 65536; // 64 MB in KiB
pub const ARGON2_T_COST: u32 = 3; // iterations
pub const ARGON2_P_COST: u32 = 4; // parallelism/threads
pub const ARGON2_OUTPUT_LEN: usize = 32; // 256-bit output

/// Ring buffer cap for the host agent.
pub const RING_BUFFER_SIZE: usize = 2 * 1024 * 1024; // 2 MB

/// XChaCha20-Poly1305 constants.
pub const NONCE_LEN: usize = 24;
pub const MAC_LEN: usize = 16;
