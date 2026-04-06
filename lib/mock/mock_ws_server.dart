import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:pqcrypto/pqcrypto.dart';

/// Standalone mock WebSocket server for local KTTY development.
/// Run: dart run lib/mock/mock_ws_server.dart
void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('Mock KTTY server listening on ws://localhost:8080'); // ignore: avoid_print

  await for (final request in server) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final ws = await WebSocketTransformer.upgrade(request);
      print('Client connected'); // ignore: avoid_print
      _handleClient(ws);
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('WebSocket only')
        ..close();
    }
  }
}

void _handleClient(WebSocket ws) {
  final kem = PqcKem.kyber768;
  Uint8List? sharedSecret;
  Xchacha20? cipher;
  int seq = 0;

  ws.listen(
    (data) async {
      final str = data as String;
      print('Received: $str'); // ignore: avoid_print

      try {
        final json = jsonDecode(str) as Map<String, dynamic>;

        // Handle room join
        if (json['action'] == 'join') {
          print('Client joined room: ${json['room_id']}'); // ignore: avoid_print

          // Generate ML-KEM keypair and send public key
          final (pk, sk) = kem.generateKeyPair();
          _serverSk = sk;

          ws.add(jsonEncode({
            'type': 'handshake',
            'mlkem_pub_key': base64Encode(pk),
          }));
          return;
        }

        // Handle handshake response (client's ciphertext)
        if (json['type'] == 'handshake' && json['mlkem_ciphertext'] != null) {
          final ct = Uint8List.fromList(
            base64Decode(json['mlkem_ciphertext'] as String),
          );

          // Decapsulate to get shared secret
          sharedSecret = kem.decapsulate(_serverSk!, ct);
          cipher = Xchacha20.poly1305Aead();

          print('Handshake complete. Shared secret established.'); // ignore: avoid_print

          // Send encrypted welcome message
          seq++;
          final welcome = utf8.encode('Welcome to KTTY Mock Server!\r\n\$ ');
          final encrypted = await _encrypt(cipher!, sharedSecret!, welcome);

          ws.add(jsonEncode({
            'seq': seq,
            'type': 'pty',
            'payload': base64Encode(encrypted),
          }));
          return;
        }

        // Handle encrypted pty data
        if (json['type'] == 'pty' && sharedSecret != null && cipher != null) {
          final payloadB64 = json['payload'] as String;
          final packed = Uint8List.fromList(base64Decode(payloadB64));
          final decrypted = await _decrypt(cipher!, sharedSecret!, packed);
          final text = utf8.decode(decrypted, allowMalformed: true);

          print('Decrypted input: ${text.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}'); // ignore: avoid_print

          // Echo response
          String response;
          if (text == '\r' || text == '\n') {
            response = '\r\n\$ ';
          } else if (text == '\x03') {
            response = '^C\r\n\$ ';
          } else if (text == '\x04') {
            response = '\r\nlogout\r\n';
            ws.close();
            return;
          } else {
            response = text; // Echo character
          }

          seq++;
          final encrypted = await _encrypt(
            cipher!, sharedSecret!, utf8.encode(response),
          );

          ws.add(jsonEncode({
            'seq': seq,
            'type': 'pty',
            'payload': base64Encode(encrypted),
          }));
          return;
        }
      } catch (e) {
        print('Error: $e'); // ignore: avoid_print
      }
    },
    onDone: () => print('Client disconnected'), // ignore: avoid_print
    onError: (e) => print('Error: $e'), // ignore: avoid_print
  );
}

Uint8List? _serverSk;

Future<Uint8List> _encrypt(
  Xchacha20 cipher,
  Uint8List key,
  List<int> plaintext,
) async {
  final secretKey = SecretKey(List<int>.from(key));
  final secretBox = await cipher.encrypt(plaintext, secretKey: secretKey);
  final nonce = secretBox.nonce;
  final ct = secretBox.cipherText;
  final mac = secretBox.mac.bytes;
  final result = Uint8List(nonce.length + ct.length + mac.length);
  result.setAll(0, nonce);
  result.setAll(nonce.length, ct);
  result.setAll(nonce.length + ct.length, mac);
  return result;
}

Future<Uint8List> _decrypt(
  Xchacha20 cipher,
  Uint8List key,
  Uint8List packed,
) async {
  const nonceLen = 24;
  const macLen = 16;
  final nonce = packed.sublist(0, nonceLen);
  final ct = packed.sublist(nonceLen, packed.length - macLen);
  final macBytes = packed.sublist(packed.length - macLen);
  final secretKey = SecretKey(List<int>.from(key));
  final secretBox = SecretBox(ct, nonce: nonce, mac: Mac(macBytes));
  final plaintext = await cipher.decrypt(secretBox, secretKey: secretKey);
  return Uint8List.fromList(plaintext);
}
