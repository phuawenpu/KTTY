import 'dart:typed_data';
import 'native_crypto_web.dart' if (dart.library.io) 'native_crypto_ffi.dart'
    as impl;

class NativeCrypto {
  static bool get isCryptoAvailable => impl.isCryptoAvailable;

  static Future<Uint8List> deriveKey(String pin) => impl.deriveKey(pin);

  static Future<String> roomId(Uint8List derivedKey) =>
      impl.roomId(derivedKey);

  static Future<Uint8List> encrypt(Uint8List key, Uint8List plaintext) =>
      impl.encrypt(key, plaintext);

  static Future<Uint8List> decrypt(Uint8List key, Uint8List packed) =>
      impl.decrypt(key, packed);

  static Future<(Uint8List ciphertext, Uint8List sharedSecret)>
      mlkemEncapsulate(Uint8List ekBytes) => impl.mlkemEncapsulate(ekBytes);

  static Future<bool> verifyHmac(
          Uint8List argon2Key, Uint8List data, Uint8List expected) =>
      impl.verifyHmac(argon2Key, data, expected);

  static Future<Uint8List> computeHmac(Uint8List argon2Key, Uint8List data) =>
      impl.computeHmac(argon2Key, data);
}
