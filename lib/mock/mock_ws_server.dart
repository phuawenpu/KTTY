import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pqcrypto/pqcrypto.dart';

/// Mock WebSocket server for local KTTY development.
/// Completes ML-KEM handshake but uses plain base64 payloads (no encryption).
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
  bool handshakeComplete = false;
  int seq = 0;

  ws.listen(
    (data) {
      final str = data as String;

      try {
        final json = jsonDecode(str) as Map<String, dynamic>;

        // Handle room join
        if (json['action'] == 'join') {
          print('Join room: ${json['room_id']}'); // ignore: avoid_print

          final (pk, sk) = kem.generateKeyPair();
          // Store sk but we won't actually use it for encryption
          final _ = sk;

          ws.add(jsonEncode({
            'type': 'handshake',
            'mlkem_pub_key': base64Encode(pk),
          }));
          return;
        }

        // Handle handshake response
        if (json['type'] == 'handshake' && json['mlkem_ciphertext'] != null) {
          handshakeComplete = true;
          print('Handshake complete (mock mode - no encryption)'); // ignore: avoid_print

          // Send welcome as plain base64
          seq++;
          final welcome = 'Welcome to KTTY Mock Server!\r\n\$ ';
          ws.add(jsonEncode({
            'seq': seq,
            'type': 'pty',
            'payload': base64Encode(utf8.encode(welcome)),
          }));
          return;
        }

        // Handle pty data
        if (json['type'] == 'pty' && handshakeComplete) {
          final payloadB64 = json['payload'] as String;

          // Try to decode as plain base64 first
          String text;
          try {
            final bytes = base64Decode(payloadB64);
            text = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {
            text = '?';
          }

          // If it looks like encrypted data (has nonce prefix), just
          // acknowledge with a plain response
          if (text.isEmpty || text.codeUnitAt(0) > 127) {
            // Likely encrypted payload we can't read
            seq++;
            ws.add(jsonEncode({
              'seq': seq,
              'type': 'pty',
              'payload': base64Encode(utf8.encode('.')),
            }));
            return;
          }

          print('Input: ${text.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}'); // ignore: avoid_print

          // Echo response
          String response;
          if (text == '\r' || text == '\n') {
            response = '\r\n\$ ';
          } else if (text == '\x7F' || text == '\b') {
            // Backspace: move cursor back, overwrite with space, move back
            response = '\b \b';
          } else if (text == '\x1b[3~') {
            // Delete key: erase character at cursor
            response = '\x1b[P';
          } else if (text == '\x03') {
            response = '^C\r\n\$ ';
          } else if (text == '\x04') {
            ws.close();
            return;
          } else if (text.startsWith('\x1b')) {
            // Escape sequences (arrows, function keys) — echo as-is
            response = text;
          } else {
            response = text;
          }

          seq++;
          ws.add(jsonEncode({
            'seq': seq,
            'type': 'pty',
            'payload': base64Encode(utf8.encode(response)),
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
