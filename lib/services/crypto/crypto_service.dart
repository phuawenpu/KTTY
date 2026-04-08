import 'dart:typed_data';
import 'native_crypto.dart';

class CryptoService {
  final Uint8List _key;

  CryptoService(this._key);

  /// Encrypt plaintext. Returns nonce(24) || ciphertext || tag(16).
  Future<Uint8List> encrypt(List<int> plaintext) async {
    return NativeCrypto.encrypt(_key, Uint8List.fromList(plaintext));
  }

  /// Decrypt packed data (nonce || ciphertext || tag).
  Future<Uint8List> decrypt(Uint8List packed) async {
    return NativeCrypto.decrypt(_key, packed);
  }
}
