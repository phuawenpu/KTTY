import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Static salt agreed upon by Flutter and Golang teams.
final Uint8List kStaticSalt = Uint8List.fromList(
  utf8.encode('KTTY STATIC SALT VERSION 1'),
);

/// Argon2id parameters synchronized with the Golang host agent.
final _argon2id = Argon2id(
  memory: 65536,     // 64 MB (65536 KB)
  iterations: 3,     // Time cost
  parallelism: 4,    // Threads
  hashLength: 32,    // 256-bit output
);

class PinUtils {
  /// Derive a 32-byte Argon2id hash from the user PIN.
  /// Used for both Room ID generation and HMAC key derivation.
  static Future<Uint8List> deriveKey(String pin) async {
    final secretKey = SecretKey(utf8.encode(pin));
    final derivedKey = await _argon2id.deriveKey(
      secretKey: secretKey,
      nonce: kStaticSalt,
    );
    final bytes = await derivedKey.extractBytes();
    return Uint8List.fromList(bytes);
  }

  /// Generate the Room ID as a hex string from Argon2id(PIN).
  static Future<String> hashPin(String pin) async {
    final hash = await deriveKey(pin);
    return hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
