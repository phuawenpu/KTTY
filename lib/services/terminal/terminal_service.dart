import 'dart:async';
import 'dart:convert';
import 'package:xterm/xterm.dart';
import '../../config/constants.dart';
import '../websocket/websocket_service.dart';

/// Rolling-window latency + traffic stats for the terminal session.
/// Owned by [TerminalService]; surfaced to the user via the info-button
/// dialog in `lib/screens/terminal_screen.dart`.
class TerminalStats {
  /// Capacity of the rolling RTT samples buffer (one entry per matched
  /// keystroke echo).
  final int capacity;

  final List<int> _rttSamples = <int>[];
  int _bytesSent = 0;
  int _bytesReceived = 0;
  int _messagesSent = 0;
  int _messagesReceived = 0;
  int? _sessionStartedAtMs;

  TerminalStats({this.capacity = 100});

  void noteSent(int byteCount) {
    _bytesSent += byteCount;
    _messagesSent++;
  }

  void noteReceived(int byteCount) {
    _bytesReceived += byteCount;
    _messagesReceived++;
  }

  /// Record one keystroke round-trip time (ms from local echo prediction
  /// to the matching byte arriving back from the server).
  void noteRtt(int ms) {
    if (ms < 0 || ms > 60000) return; // sanity clamp
    _rttSamples.add(ms);
    if (_rttSamples.length > capacity) _rttSamples.removeAt(0);
  }

  void markSessionStart() {
    _sessionStartedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// Reset everything (typically on disconnect).
  void reset() {
    _rttSamples.clear();
    _bytesSent = 0;
    _bytesReceived = 0;
    _messagesSent = 0;
    _messagesReceived = 0;
    _sessionStartedAtMs = null;
  }

  int get sampleCount => _rttSamples.length;
  int? get lastRttMs => _rttSamples.isEmpty ? null : _rttSamples.last;
  double? get averageRttMs => _rttSamples.isEmpty
      ? null
      : _rttSamples.reduce((a, b) => a + b) / _rttSamples.length;
  int? get minRttMs => _rttSamples.isEmpty
      ? null
      : _rttSamples.reduce((a, b) => a < b ? a : b);
  int? get maxRttMs => _rttSamples.isEmpty
      ? null
      : _rttSamples.reduce((a, b) => a > b ? a : b);
  int get bytesSent => _bytesSent;
  int get bytesReceived => _bytesReceived;
  int get messagesSent => _messagesSent;
  int get messagesReceived => _messagesReceived;

  /// Session uptime in seconds, or `null` if no session has started.
  int? get sessionAgeSeconds {
    if (_sessionStartedAtMs == null) return null;
    return (DateTime.now().millisecondsSinceEpoch - _sessionStartedAtMs!) ~/ 1000;
  }
}

/// One predicted-echo entry: the byte we echoed locally + when. The byte
/// is matched against incoming server data; on match we compute
/// `now - sentTimeMs` and feed it to [TerminalStats.noteRtt].
class _EchoEntry {
  final int byte;
  final int sentTimeMs;
  const _EchoEntry(this.byte, this.sentTimeMs);
}

class TerminalService {
  final Terminal terminal;
  final TerminalController controller;
  final WebSocketService _ws;
  StreamSubscription? _wsSubscription;
  int _seq = 0;
  bool _plainFallback = false;
  Timer? _resizeDebounce;
  bool _firstResize = true;

  /// Public stats accumulator. Read by the info dialog.
  final TerminalStats stats = TerminalStats();

  // Keystroke batching: buffer input and flush every 50ms
  List<int> _inputBuffer = [];
  Timer? _inputFlushTimer;
  static const _inputFlushInterval = Duration(milliseconds: 50);

  // Local echo prediction: track chars we echoed locally so we can
  // (a) suppress the duplicate when the server echoes them back, and
  // (b) measure the keystroke-to-echo round-trip latency. Each entry
  // carries the timestamp at which we predicted the echo.
  final List<_EchoEntry> _predictedEcho = <_EchoEntry>[];

  TerminalService(this._ws)
      : terminal = Terminal(maxLines: kTerminalMaxLines),
        controller = TerminalController();

  /// Get the currently selected text from the terminal buffer.
  String getSelectedText() {
    final selection = controller.selection;
    if (selection == null) return '';
    return terminal.buffer.getText(selection);
  }

  /// Send text directly to the PTY as if the user typed it.
  /// More reliable than terminal.textInput() for injecting words
  /// because it bypasses xterm internals and goes straight to the send buffer.
  void sendText(String text) {
    final bytes = utf8.encode(text);
    _inputBuffer.addAll(bytes);
    _inputFlushTimer ??= Timer(_inputFlushInterval, _flushInput);
  }

  void attach() {
    stats.markSessionStart();

    // Terminal output (user keystrokes) → local echo + batched send
    terminal.onOutput = (data) {
      final bytes = utf8.encode(data);

      // Local echo: show printable characters immediately so the user
      // doesn't wait for the server round-trip. Track what we echoed
      // so we can (a) suppress the duplicate when the server echoes
      // back and (b) measure end-to-end keystroke latency.
      // Skip local echo entirely if the data contains escape sequences
      // (e.g. terminal query responses like DA, DECRPM) — those are not
      // user-typed characters and would show as garbage like ";OR;OR".
      final hasEscape = bytes.contains(0x1B);
      if (!hasEscape) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (final b in bytes) {
          if (b >= 0x20 && b <= 0x7E) {
            terminal.write(String.fromCharCode(b));
            _predictedEcho.add(_EchoEntry(b, nowMs));
          }
        }
      }

      // Buffer keystrokes and flush every 50ms to reduce WS messages
      _inputBuffer.addAll(bytes);
      _inputFlushTimer ??= Timer(_inputFlushInterval, _flushInput);
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

  void _flushInput() {
    _inputFlushTimer = null;
    if (_inputBuffer.isEmpty) return;
    final batch = _inputBuffer;
    _inputBuffer = [];
    _sendPty(batch);
  }

  /// Remove leading bytes from server response that match our local echo
  /// predictions. On match, also feed each matched echo's age into the
  /// rolling RTT stats so the user can see end-to-end keystroke latency.
  /// On mismatch, clear predictions and return all bytes unfiltered.
  List<int> _stripPredictedEcho(List<int> incoming) {
    if (_predictedEcho.isEmpty) return incoming;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    int matched = 0;
    for (int i = 0; i < incoming.length && matched < _predictedEcho.length; i++) {
      if (incoming[i] == _predictedEcho[matched].byte) {
        stats.noteRtt(nowMs - _predictedEcho[matched].sentTimeMs);
        matched++;
      } else {
        // Mismatch — prediction was wrong (vim, stty -echo, etc.)
        // Clear predictions and return everything unfiltered.
        _predictedEcho.clear();
        return incoming;
      }
    }

    // Remove matched predictions
    _predictedEcho.removeRange(0, matched);

    // Return the unmatched tail (e.g. shell prompt after the echo)
    if (matched < incoming.length) {
      return incoming.sublist(matched);
    }
    return [];
  }

  Future<void> _sendPty(List<int> data) async {
    _seq++;
    stats.noteSent(data.length);
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

      // Skip handshake/boot messages — these are internal handshake signals,
      // not terminal data. The boot signal arrives during normal reconnection.
      if (type == 'handshake' || type == 'boot') return;

      // Join notification from relay — ignore (handled by handshake flow)
      if (json['action'] == 'join') return;

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

        stats.noteReceived(bytes.length);

        // Strip bytes that match local echo predictions. The strip pass
        // also feeds end-to-end keystroke latency samples into `stats`
        // so the info dialog can show RTT — see _stripPredictedEcho.
        final filtered = _stripPredictedEcho(bytes);
        if (filtered.isNotEmpty) {
          terminal.write(utf8.decode(filtered, allowMalformed: true));
        }

        // Track the agent's outgoing seq (used for sync_req replays)
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

  /// Re-attach after an auto-reconnect. Silently re-establishes the
  /// terminal bridge and requests ring buffer sync from the agent.
  /// Does NOT clear the screen — the existing buffer stays visible
  /// while sync restores the current state in the background.
  void reattachAfterReconnect() {
    if (terminal.onOutput == null) {
      attach();
    }
    _predictedEcho.clear();
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
    _inputFlushTimer?.cancel();
    _inputFlushTimer = null;
    if (_inputBuffer.isNotEmpty) {
      _sendPty(_inputBuffer);
      _inputBuffer = [];
    }
    _wsSubscription?.cancel();
    _wsSubscription = null;
  }

  void dispose() {
    detach();
  }
}
