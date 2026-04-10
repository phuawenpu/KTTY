import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:pqcrypto/pqcrypto.dart' as pqcrypto;

const _staticSalt = 'KTTY STATIC SALT VERSION 1';
const _argon2MCost = 65536; // 64 MB
const _argon2TCost = 3;
const _argon2PCost = 4;
const _argon2OutputLen = 32;
const _nonceLen = 24;

bool get isCryptoAvailable => true;

Future<Uint8List> deriveKey(String pin) async {
  final argon2 = Argon2id(
    memory: _argon2MCost,
    iterations: _argon2TCost,
    parallelism: _argon2PCost,
    hashLength: _argon2OutputLen,
  );
  final result = await argon2.deriveKey(
    secretKey: SecretKey(utf8.encode(pin)),
    nonce: utf8.encode(_staticSalt),
  );
  final bytes = await result.extractBytes();
  return Uint8List.fromList(bytes);
}

Future<String> roomId(Uint8List derivedKey) async {
  final sb = StringBuffer();
  for (final b in derivedKey) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Future<Uint8List> encrypt(Uint8List key, Uint8List plaintext) async {
  final algo = Xchacha20.poly1305Aead();
  final secretKey = SecretKey(key);
  final secretBox = await algo.encrypt(
    plaintext,
    secretKey: secretKey,
  );
  // Pack: nonce(24) || ciphertext || mac(16)
  final packed = Uint8List(_nonceLen + secretBox.cipherText.length + secretBox.mac.bytes.length);
  packed.setAll(0, secretBox.nonce);
  packed.setAll(_nonceLen, secretBox.cipherText);
  packed.setAll(_nonceLen + secretBox.cipherText.length, secretBox.mac.bytes);
  return packed;
}

Future<Uint8List> decrypt(Uint8List key, Uint8List packed) async {
  if (packed.length < _nonceLen + 16) {
    throw ArgumentError('Invalid packed data length');
  }
  final algo = Xchacha20.poly1305Aead();
  final secretKey = SecretKey(key);
  final nonce = packed.sublist(0, _nonceLen);
  final cipherText = packed.sublist(_nonceLen, packed.length - 16);
  final mac = Mac(packed.sublist(packed.length - 16));
  final secretBox = SecretBox(
    cipherText,
    nonce: nonce,
    mac: mac,
  );
  final decrypted = await algo.decrypt(secretBox, secretKey: secretKey);
  return Uint8List.fromList(decrypted);
}

Future<(Uint8List, Uint8List)> mlkemEncapsulate(Uint8List ekBytes) async {
  final kem = pqcrypto.KyberKem(pqcrypto.KyberLevel.kem768);
  final (ct, ss) = kem.encapsulate(ekBytes);
  return (ct, ss);
}

Future<bool> verifyHmac(
    Uint8List argon2Key, Uint8List data, Uint8List expected) async {
  final hmac = Hmac.sha256();
  final mac = await hmac.calculateMac(
    data,
    secretKey: SecretKey(argon2Key),
  );
  final computed = Uint8List.fromList(mac.bytes);
  if (computed.length != expected.length) return false;
  int result = 0;
  for (int i = 0; i < computed.length; i++) {
    result |= computed[i] ^ expected[i];
  }
  return result == 0;
}

Future<Uint8List> computeHmac(Uint8List argon2Key, Uint8List data) async {
  final hmac = Hmac.sha256();
  final mac = await hmac.calculateMac(
    data,
    secretKey: SecretKey(argon2Key),
  );
  return Uint8List.fromList(mac.bytes);
}
