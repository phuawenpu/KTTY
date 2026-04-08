import 'dart:typed_data';
import 'native_crypto.dart';

class PinUtils {
  /// Derive a 32-byte Argon2id key from the user's PIN.
  static Future<Uint8List> deriveKey(String pin) async {
    return NativeCrypto.deriveKey(pin);
  }

  /// Generate a room ID (hex string) from the PIN.
  static Future<String> hashPin(String pin) async {
    final key = await deriveKey(pin);
    return NativeCrypto.roomId(key);
  }
}
