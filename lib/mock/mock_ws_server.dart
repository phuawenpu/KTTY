import 'dart:convert';
import 'dart:io';

/// Mock WebSocket server for local KTTY development.
/// NOTE: This mock does NOT support ML-KEM handshake (requires Rust FFI).
/// For full handshake testing, use the real ktty-agent binary.
/// Run: dart run lib/mock/mock_ws_server.dart
void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('Mock KTTY server listening on ws://localhost:8080'); // ignore: avoid_print
  print('WARNING: No ML-KEM support. Use real agent for handshake testing.'); // ignore: avoid_print

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
  int seq = 0;

  ws.listen(
    (data) {
      final str = data as String;
      try {
        final json = jsonDecode(str) as Map<String, dynamic>;

        if (json['action'] == 'join') {
          print('Join room: ${json['room_id']}'); // ignore: avoid_print
          // Mock server cannot perform ML-KEM handshake without Rust FFI.
          // Send boot signal so client knows agent is present.
          ws.add(jsonEncode({'type': 'boot'}));
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
