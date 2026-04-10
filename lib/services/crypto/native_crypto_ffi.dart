import 'dart:typed_data';

// Stub for native FFI — will be replaced by flutter_rust_bridge generated code.
// On native platforms, this delegates to the Rust FFI bridge.

bool get isCryptoAvailable => false;

Future<Uint8List> deriveKey(String pin) =>
    throw UnsupportedError('FFI crypto not available');

Future<String> roomId(Uint8List derivedKey) =>
    throw UnsupportedError('FFI crypto not available');

Future<Uint8List> encrypt(Uint8List key, Uint8List plaintext) =>
    throw UnsupportedError('FFI crypto not available');

Future<Uint8List> decrypt(Uint8List key, Uint8List packed) =>
    throw UnsupportedError('FFI crypto not available');

Future<(Uint8List, Uint8List)> mlkemEncapsulate(Uint8List ekBytes) =>
    throw UnsupportedError('FFI crypto not available');

Future<bool> verifyHmac(
        Uint8List argon2Key, Uint8List data, Uint8List expected) =>
    throw UnsupportedError('FFI crypto not available');

Future<Uint8List> computeHmac(Uint8List argon2Key, Uint8List data) =>
    throw UnsupportedError('FFI crypto not available');
