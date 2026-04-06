import 'dart:async';
import 'dart:convert';
import 'package:xterm/xterm.dart';
import '../../config/constants.dart';
import '../websocket/websocket_service.dart';

class TerminalService {
  final Terminal terminal;
  final WebSocketService _ws;
  StreamSubscription? _wsSubscription;
  int _seq = 0;

  TerminalService(this._ws)
      : terminal = Terminal(maxLines: kTerminalMaxLines);

  void attach() {
    // Terminal output (user keystrokes) → WebSocket
    terminal.onOutput = (data) {
      _sendPty(utf8.encode(data));
    };

    // WebSocket → Terminal input
    _wsSubscription = _ws.messages.listen((raw) {
      _handleMessage(raw);
    });
  }

  Future<void> _sendPty(List<int> data) async {
    if (_ws.isEncrypted) {
      _seq++;
      await _ws.sendEncrypted(_seq, 'pty', data);
    } else {
      // Fallback for unencrypted (Phase 1 compatibility)
      _ws.sendJson({
        'type': 'pty',
        'payload': base64Encode(data),
      });
    }
  }

  Future<void> _handleMessage(String raw) async {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final type = json['type'] as String?;

      // Skip handshake messages — handled by WebSocketService
      if (type == 'handshake') return;

      if (type == 'pty') {
        final payload = json['payload'] as String;
        List<int> bytes;

        if (_ws.isEncrypted) {
          bytes = await _ws.decryptPayload(payload);
        } else {
          bytes = base64Decode(payload);
        }

        terminal.write(utf8.decode(bytes, allowMalformed: true));

        // Track sequence number
        final seq = json['seq'] as int?;
        if (seq != null) _seq = seq;
      } else if (type == 'sync_warn') {
        final payload = json['payload'] as String;
        List<int> bytes;

        if (_ws.isEncrypted) {
          bytes = await _ws.decryptPayload(payload);
        } else {
          bytes = base64Decode(payload);
        }

        final syncData = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final droppedStart = syncData['dropped_start'];
        final droppedEnd = syncData['dropped_end'];

        // Clear screen and show warning
        terminal.write('\x1b[2J\x1b[H');
        terminal.write(
          '\r\n*** DATA LOSS WARNING: Sequences $droppedStart-$droppedEnd dropped ***\r\n',
        );
      }
    } catch (_) {
      // Fallback: write raw text
      terminal.write(raw);
    }
  }

  Future<void> sendResize(int cols, int rows) async {
    final payload = utf8.encode(jsonEncode({'cols': cols, 'rows': rows}));
    if (_ws.isEncrypted) {
      _seq++;
      await _ws.sendEncrypted(_seq, 'resize', payload);
    } else {
      _ws.sendJson({
        'type': 'resize',
        'payload': base64Encode(payload),
      });
    }
  }

  void detach() {
    terminal.onOutput = null;
    _wsSubscription?.cancel();
    _wsSubscription = null;
  }

  void dispose() {
    detach();
  }
}
