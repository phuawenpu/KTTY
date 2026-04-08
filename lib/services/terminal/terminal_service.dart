import 'dart:async';
import 'dart:convert';
import 'package:xterm/xterm.dart';
import '../../config/constants.dart';
import '../websocket/websocket_service.dart';

class TerminalService {
  final Terminal terminal;
  final TerminalController controller;
  final WebSocketService _ws;
  StreamSubscription? _wsSubscription;
  int _seq = 0;
  bool _plainFallback = false;
  Timer? _resizeDebounce;
  bool _firstResize = true;

  TerminalService(this._ws)
      : terminal = Terminal(maxLines: kTerminalMaxLines),
        controller = TerminalController();

  /// Get the currently selected text from the terminal buffer.
  String getSelectedText() {
    final selection = controller.selection;
    if (selection == null) return '';
    return terminal.buffer.getText(selection);
  }

  final _pendingTimestamps = <int, int>{};

  void attach() {
    // Terminal output (user keystrokes) → WebSocket
    terminal.onOutput = (data) {
      _sendPty(utf8.encode(data));
    };

    // Forward terminal resize events to backend PTY.
    // First resize sent immediately (critical for TUI apps like Claude Code);
    // subsequent resizes debounced to avoid flooding during drag/zoom.
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (width <= 0 || height <= 0) return;
      if (_firstResize) {
        _firstResize = false;
        print('[KTTY] Initial resize: ${width}x$height');
        sendResize(width, height);
        return;
      }
      _resizeDebounce?.cancel();
      _resizeDebounce = Timer(const Duration(milliseconds: 100), () {
        print('[KTTY] Terminal resized: ${width}x$height');
        sendResize(width, height);
      });
    };

    // WebSocket → Terminal input
    _wsSubscription = _ws.messages.listen((raw) {
      _handleMessage(raw);
    });
  }

  Future<void> _sendPty(List<int> data) async {
    _seq++;
    if (_ws.isEncrypted && !_plainFallback) {
      try {
        await _ws.sendEncrypted(_seq, 'pty', data);
      } catch (_) {
        _plainFallback = true;
        _sendPlain(data);
      }
    } else {
      _sendPlain(data);
    }
  }

  void _sendPlain(List<int> data) {
    _pendingTimestamps[_seq] = DateTime.now().millisecondsSinceEpoch;
    _ws.sendJson({
      'seq': _seq,
      'type': 'pty',
      'payload': base64Encode(data),
    });
  }

  Future<void> _handleMessage(String raw) async {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final type = json['type'] as String?;

      // Skip handshake messages
      if (type == 'handshake') return;

      // Agent restarted — clear terminal and show message
      if (type == 'boot' || json['action'] == 'join') {
        print('[KTTY] Agent restarted, clearing terminal');
        terminal.write('\x1b[2J\x1b[H');
        terminal.write('\r\n*** Session ended. Use exit button to reconnect. ***\r\n');
        return;
      }

      if (type == 'pty') {
        final payload = json['payload'] as String;
        List<int> bytes;

        if (_ws.isEncrypted) {
          try {
            bytes = await _ws.decryptPayload(payload);
          } catch (_) {
            // Decryption failed — switch to plain mode
            _plainFallback = true;
            bytes = base64Decode(payload);
          }
        } else {
          bytes = base64Decode(payload);
        }

        terminal.write(utf8.decode(bytes, allowMalformed: true));

        // Track sequence number and measure round-trip
        final seq = json['seq'] as int?;
        if (seq != null) {
          final sendTime = _pendingTimestamps.remove(seq - 1); // echo comes as seq+1
          if (sendTime != null) {
            final rtt = DateTime.now().millisecondsSinceEpoch - sendTime;
            print('[KTTY-RTT] ${rtt}ms (seq $seq)');
          }
          _seq = seq;
        }
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

  /// Re-attach after an auto-reconnect. Clears terminal and requests
  /// the agent to replay its ring buffer so TUI state is restored.
  void reattachAfterReconnect() {
    // Re-attach if not currently attached
    if (terminal.onOutput == null) {
      attach();
    }
    // Clear screen and request sync from agent
    terminal.write('\x1b[2J\x1b[H');
    terminal.write('\r\n*** Reconnecting... ***\r\n');
    _requestSync();
  }

  Future<void> _requestSync() async {
    try {
      await _ws.sendSyncRequest(_seq);
      print('[KTTY] Sync request sent (last_seq=$_seq)');
    } catch (e) {
      print('[KTTY] Failed to send sync request: $e');
    }
  }

  void detach() {
    terminal.onOutput = null;
    terminal.onResize = null;
    _resizeDebounce?.cancel();
    _wsSubscription?.cancel();
    _wsSubscription = null;
  }

  void dispose() {
    detach();
  }
}
