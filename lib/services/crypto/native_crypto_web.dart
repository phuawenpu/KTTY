import 'dart:js_interop';
import 'dart:typed_data';

@JS('window._kttyCryptoReady')
external bool? get _kttyCryptoReady;

@JS('window._kttyCrypto.deriveKey')
external JSUint8Array _deriveKey(JSString pin);

@JS('window._kttyCrypto.roomId')
external JSString _roomId(JSUint8Array derivedKey);

@JS('window._kttyCrypto.encrypt')
external JSUint8Array _encrypt(JSUint8Array key, JSUint8Array plaintext);

@JS('window._kttyCrypto.decrypt')
external JSUint8Array _decrypt(JSUint8Array key, JSUint8Array packed);

@JS('window._kttyCrypto.mlkemEncapsulate')
external JSUint8Array _mlkemEncapsulate(JSUint8Array ekBytes);

@JS('window._kttyCrypto.verifyHmac')
external JSBoolean _verifyHmac(
    JSUint8Array argon2Key, JSUint8Array data, JSUint8Array expected);

@JS('window._kttyCrypto.computeHmac')
external JSUint8Array _computeHmac(JSUint8Array argon2Key, JSUint8Array data);

bool get isCryptoAvailable {
  final ready = _kttyCryptoReady;
  return ready != null && ready == true;
}

Future<Uint8List> deriveKey(String pin) async {
  return _deriveKey(pin.toJS).toDart;
}

Future<String> roomId(Uint8List derivedKey) async {
  return _roomId(derivedKey.toJS).toDart;
}

Future<Uint8List> encrypt(Uint8List key, Uint8List plaintext) async {
  return _encrypt(key.toJS, plaintext.toJS).toDart;
}

Future<Uint8List> decrypt(Uint8List key, Uint8List packed) async {
  return _decrypt(key.toJS, packed.toJS).toDart;
}

Future<(Uint8List, Uint8List)> mlkemEncapsulate(Uint8List ekBytes) async {
  final combined = _mlkemEncapsulate(ekBytes.toJS).toDart;
  final ct = Uint8List.sublistView(combined, 0, combined.length - 32);
  final ss = Uint8List.sublistView(combined, combined.length - 32);
  return (Uint8List.fromList(ct), Uint8List.fromList(ss));
}

Future<bool> verifyHmac(
    Uint8List argon2Key, Uint8List data, Uint8List expected) async {
  return _verifyHmac(argon2Key.toJS, data.toJS, expected.toJS).toDart;
}

Future<Uint8List> computeHmac(Uint8List argon2Key, Uint8List data) async {
  return _computeHmac(argon2Key.toJS, data.toJS).toDart;
}
