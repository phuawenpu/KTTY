/// ML-KEM 768 Baseline Generator
///
/// Generates a keypair, encapsulates a shared secret, and prints all values
/// as hex strings for cross-language interoperability testing.
///
/// Output:
///   - Decapsulation (private) key
///   - Encapsulation (public) key
///   - Ciphertext
///   - Shared secret
///
/// The Dart side should be able to take the private key + ciphertext
/// and produce the same shared secret via decapsulation.
use ml_kem::kem::{Decapsulate, Encapsulate};
use ml_kem::{EncodedSizeUser, KemCore, MlKem768};

fn main() {
    let mut rng = rand::thread_rng();

    // Generate keypair
    let (dk, ek) = MlKem768::generate(&mut rng);

    // Encapsulate: produces ciphertext + shared secret
    let (ct, shared_secret) = ek.encapsulate(&mut rng).unwrap();

    // Verify: decapsulate should produce the same shared secret
    let shared_secret_verify = dk.decapsulate(&ct).unwrap();
    assert_eq!(
        shared_secret.as_slice(),
        shared_secret_verify.as_slice(),
        "Self-test failed: encapsulate/decapsulate mismatch"
    );

    // Print all values as hex
    let dk_bytes = dk.as_bytes();
    let ek_bytes = ek.as_bytes();
    let ct_bytes = ct.as_slice();
    let ss_bytes = shared_secret.as_slice();

    println!("=== ML-KEM 768 Baseline ===");
    println!("DK (private key) [{} bytes]: {}", dk_bytes.len(), hex::encode(dk_bytes));
    println!("EK (public key) [{} bytes]: {}", ek_bytes.len(), hex::encode(ek_bytes));
    println!("CT (ciphertext) [{} bytes]: {}", ct_bytes.len(), hex::encode(ct_bytes));
    println!("SS (shared secret) [{} bytes]: {}", ss_bytes.len(), hex::encode(ss_bytes));
    println!();
    println!("Self-test: PASSED (decapsulation matches encapsulation)");

    // Also print in a format easy to paste into Dart
    println!();
    println!("=== For Dart test script ===");
    println!("const dk_hex = '{}';", hex::encode(dk_bytes));
    println!("const ek_hex = '{}';", hex::encode(ek_bytes));
    println!("const ct_hex = '{}';", hex::encode(ct_bytes));
    println!("const ss_hex = '{}';", hex::encode(ss_bytes));
}
