import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pqcrypto/pqcrypto.dart';

class HandshakeResult {
  final Uint8List ciphertext;
  final Uint8List sharedSecret;

  HandshakeResult({required this.ciphertext, required this.sharedSecret});
}

class HandshakeService {
  static final _kem = PqcKem.kyber768;

  /// Encapsulate a shared secret using the host's ML-KEM public key.
  static HandshakeResult encapsulate(Uint8List mlkemPubKey) {
    final (ct, ss) = _kem.encapsulate(mlkemPubKey);
    return HandshakeResult(ciphertext: ct, sharedSecret: ss);
  }

  /// Verify the handshake wasn't tampered with (MITM check).
  /// Uses the Argon2id-derived key (not raw PIN) as HMAC key.
  static bool verifyHmac(
    Uint8List argon2DerivedKey,
    Uint8List sharedSecret,
    Uint8List expectedHmac,
  ) {
    final hmacSha256 = Hmac(sha256, argon2DerivedKey);
    final computed = hmacSha256.convert(sharedSecret);
    final computedBytes = Uint8List.fromList(computed.bytes);

    if (computedBytes.length != expectedHmac.length) return false;
    int result = 0;
    for (int i = 0; i < computedBytes.length; i++) {
      result |= computedBytes[i] ^ expectedHmac[i];
    }
    return result == 0;
  }

  /// Generate a keypair for the mock server side.
  static (Uint8List publicKey, Uint8List secretKey) generateKeyPair() {
    return _kem.generateKeyPair();
  }

  /// Decapsulate (server side / mock server).
  static Uint8List decapsulate(Uint8List secretKey, Uint8List ciphertext) {
    return _kem.decapsulate(secretKey, ciphertext);
  }
}
