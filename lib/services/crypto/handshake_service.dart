import 'dart:typed_data';
import 'native_crypto.dart';

class HandshakeResult {
  final Uint8List ciphertext;
  final Uint8List sharedSecret;
  HandshakeResult({required this.ciphertext, required this.sharedSecret});
}

class HandshakeService {
  /// Encapsulate a shared secret using the agent's ML-KEM public key.
  static Future<HandshakeResult> encapsulate(Uint8List mlkemPubKey) async {
    final (ct, ss) = await NativeCrypto.mlkemEncapsulate(mlkemPubKey);
    return HandshakeResult(ciphertext: ct, sharedSecret: ss);
  }

  /// Verify the agent's HMAC (MITM detection).
  static Future<bool> verifyHmac(
    Uint8List argon2DerivedKey,
    Uint8List sharedSecret,
    Uint8List expectedHmac,
  ) async {
    return NativeCrypto.verifyHmac(argon2DerivedKey, sharedSecret, expectedHmac);
  }

  /// Compute HMAC-SHA256.
  static Future<Uint8List> computeHmac(
    Uint8List argon2DerivedKey,
    Uint8List data,
  ) async {
    return NativeCrypto.computeHmac(argon2DerivedKey, data);
  }
}
