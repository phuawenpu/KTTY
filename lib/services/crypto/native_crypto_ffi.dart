import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';

const _staticSalt = 'KTTY STATIC SALT VERSION 1';
const _argon2MCost = 65536; // 64 MB
const _argon2TCost = 3;
const _argon2PCost = 4;
const _argon2OutputLen = 32;
const _nonceLen = 24;

// ML-KEM-768 fixed sizes (FIPS 203)
const _mlkemEkLen = 1184;
const _mlkemCtLen = 1088;
const _mlkemSsLen = 32;

// ---------------------------------------------------------------------------
// dart:ffi bindings for the Rust `ktty-ffi-crypto` cdylib.
//
// All crypto except ML-KEM is handled in pure Dart by `package:cryptography`,
// because Argon2id, XChaCha20-Poly1305, and HMAC-SHA256 are standardized and
// have stable Dart implementations. ML-KEM is the lone exception: the Dart
// `pqcrypto` package implements an older CRYSTALS-Kyber draft that produces
// different shared secrets than the FIPS 203 ML-KEM in the Rust `ml-kem`
// crate (which the agent uses). The interop test in
// `tests/mlkem_interop/` confirms this. So for ML-KEM we call into the same
// Rust crate as the agent via FFI.
// ---------------------------------------------------------------------------

typedef _MlkemEncapsulateNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);
typedef _MlkemEncapsulateDart = int Function(
    ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>);

ffi.DynamicLibrary _openLib() {
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('libktty_ffi_crypto.so');
  }
  if (Platform.isMacOS) {
    return ffi.DynamicLibrary.open('libktty_ffi_crypto.dylib');
  }
  if (Platform.isIOS) {
    // iOS statically links the .a into the app binary
    return ffi.DynamicLibrary.process();
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('ktty_ffi_crypto.dll');
  }
  throw UnsupportedError('Unsupported platform for ktty_ffi_crypto');
}

late final ffi.DynamicLibrary _lib = _openLib();
late final _MlkemEncapsulateDart _mlkemEncapsulate = _lib
    .lookup<ffi.NativeFunction<_MlkemEncapsulateNative>>('ktty_mlkem_encapsulate')
    .asFunction<_MlkemEncapsulateDart>();

bool get isCryptoAvailable {
  // Touch the lib to confirm it loads. Any failure here means the .so was
  // not bundled into the APK; the caller surfaces a friendly error.
  try {
    final probe = _lib.lookup<ffi.NativeFunction<ffi.Uint32 Function()>>(
        'ktty_ffi_crypto_version');
    return probe.address != 0;
  } catch (_) {
    return false;
  }
}

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
  if (ekBytes.length != _mlkemEkLen) {
    throw ArgumentError(
        'ML-KEM-768 encapsulation key must be $_mlkemEkLen bytes, got ${ekBytes.length}');
  }

  final ekPtr = calloc<ffi.Uint8>(_mlkemEkLen);
  final ctPtr = calloc<ffi.Uint8>(_mlkemCtLen);
  final ssPtr = calloc<ffi.Uint8>(_mlkemSsLen);
  try {
    ekPtr.asTypedList(_mlkemEkLen).setAll(0, ekBytes);
    final rc = _mlkemEncapsulate(ekPtr, ctPtr, ssPtr);
    if (rc != 0) {
      throw StateError('ML-KEM encapsulation failed (rc=$rc)');
    }
    final ct = Uint8List.fromList(ctPtr.asTypedList(_mlkemCtLen));
    final ss = Uint8List.fromList(ssPtr.asTypedList(_mlkemSsLen));
    return (ct, ss);
  } finally {
    calloc.free(ekPtr);
    calloc.free(ctPtr);
    calloc.free(ssPtr);
  }
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
