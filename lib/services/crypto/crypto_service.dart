import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class CryptoService {
  final SecretKey _key;
  late final Xchacha20 _cipher;

  CryptoService(Uint8List keyBytes)
      : _key = SecretKey(List<int>.from(keyBytes)) {
    _cipher = Xchacha20.poly1305Aead();
  }

  /// Encrypt plaintext bytes. Returns nonce (24) + ciphertext + mac (16).
  Future<Uint8List> encrypt(List<int> plaintext) async {
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: _key,
    );

    // Pack: nonce (24 bytes) + ciphertext + mac (16 bytes)
    final nonce = secretBox.nonce;
    final ct = secretBox.cipherText;
    final mac = secretBox.mac.bytes;

    final result = Uint8List(nonce.length + ct.length + mac.length);
    result.setAll(0, nonce);
    result.setAll(nonce.length, ct);
    result.setAll(nonce.length + ct.length, mac);
    return result;
  }

  /// Decrypt packed bytes (nonce + ciphertext + mac).
  Future<Uint8List> decrypt(Uint8List packed) async {
    const nonceLen = 24;
    const macLen = 16;

    final nonce = packed.sublist(0, nonceLen);
    final ct = packed.sublist(nonceLen, packed.length - macLen);
    final macBytes = packed.sublist(packed.length - macLen);

    final secretBox = SecretBox(
      ct,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final plaintext = await _cipher.decrypt(
      secretBox,
      secretKey: _key,
    );

    return Uint8List.fromList(plaintext);
  }
}
