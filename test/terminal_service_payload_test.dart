// Tests for the payload-leak fix in terminal_service.dart.
//
// What we're guarding against: previously, if a WebSocket frame
// failed jsonDecode and didn't match a narrow heuristic
// (`trimmed.startsWith('{') && contains("payload"|"type"|"seq")`),
// the raw string was written directly into the xterm buffer via
// `terminal.write(raw)`. That leaked partial envelope fragments —
// e.g. `"payload":"<base64>"` — onto the user's screen.
//
// The fix removes the raw-write fallback entirely. Every parse
// failure now logs + triggers sync recovery. These tests exercise
// that invariant across a range of malformed inputs.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ktty/services/terminal/terminal_service.dart';
import 'package:ktty/services/websocket/websocket_service.dart';

/// Extract whatever has been "written" into the xterm buffer, stripping
/// the empty-row "N: |...|" framing xterm.toString() emits for a
/// blank terminal. Anything left is actual content that reached the
/// user's screen.
String _visibleContent(TerminalService svc) {
  final raw = svc.terminal.buffer.toString();
  final lines = raw.split('\n');
  final content = StringBuffer();
  for (final line in lines) {
    // Strip leading "NN: " prefix and surrounding pipes, then see
    // what's left.
    final m = RegExp(r'^\s*\d+:\s*\|(.*)\|\s*$').firstMatch(line);
    final inside = m != null ? m.group(1)! : line;
    if (inside.trim().isNotEmpty) content.write(inside);
  }
  return content.toString();
}

void main() {
  group('TerminalService.looksLikeWireFragment', () {
    test('matches a full envelope JSON string', () {
      expect(
        TerminalService.looksLikeWireFragment(
          '{"seq":1,"type":"pty","payload":"abc=="}',
        ),
        isTrue,
      );
    });

    test('matches a bare fragment beginning with payload key', () {
      expect(
        TerminalService.looksLikeWireFragment('"payload":"abcdef"'),
        isTrue,
      );
    });

    test('matches fragments carrying any envelope key', () {
      for (final frag in [
        '"type":"pty"',
        '"seq":42',
        '"session_id":"deadbeef"',
        '"auth":"tok"',
      ]) {
        expect(
          TerminalService.looksLikeWireFragment(frag),
          isTrue,
          reason: 'should detect fragment: $frag',
        );
      }
    });

    test('matches a JSON object even without envelope keys', () {
      // A partial object (e.g. a control message) should still be
      // treated as wire-layer so it never reaches the terminal.
      expect(
        TerminalService.looksLikeWireFragment('{"unknown":true}'),
        isTrue,
      );
    });

    test('rejects empty / whitespace-only', () {
      expect(TerminalService.looksLikeWireFragment(''), isFalse);
      expect(TerminalService.looksLikeWireFragment('   \n\t'), isFalse);
    });

    test('rejects plain user text (no envelope keys)', () {
      // A regression check: a TUI line that happens to not look like
      // JSON should be classified as non-fragment. Note that in the
      // new code path we drop it anyway, but via the "non-JSON WS
      // frame" branch — we want to know which branch fires so logs
      // are actionable.
      expect(
        TerminalService.looksLikeWireFragment('hello world\n'),
        isFalse,
      );
    });

    test('tolerates leading whitespace before brace', () {
      expect(
        TerminalService.looksLikeWireFragment('   \n\t{"type":"pty"}'),
        isTrue,
      );
    });
  });

  group('TerminalService._handleMessage payload-leak regression', () {
    late WebSocketService ws;
    late TerminalService svc;

    setUp(() {
      // Silence "Don't invoke print in production code" — these
      // services log freely via print(). During tests we just want
      // them to run; let them write to stdout.
      debugPrint = (String? msg, {int? wrapWidth}) {};
      ws = WebSocketService();
      svc = TerminalService(ws);
      // Don't call attach() — that sets terminal.onOutput/onResize,
      // starts WS subscription, and needs a real connection. We're
      // exercising the message handler directly.
    });

    tearDown(() {
      try {
        ws.dispose();
      } catch (_) {}
    });

    test('malformed envelope fragment does NOT reach the terminal', () async {
      await svc.handleMessageForTesting('"payload":"aGVsbG8="');
      // terminal.buffer.toString() would show any leaked content.
      // We assert the visible screen is empty (modulo default blank
      // buffer — xterm's initial buffer contains only whitespace).
      final screen = _visibleContent(svc);
      expect(
        screen,
        isEmpty,
        reason: 'Raw payload fragment leaked into the terminal',
      );
      expect(svc.lastSyncRecoveryReasonForTesting, isNotNull);
    });

    test('garbage non-JSON does NOT reach the terminal', () async {
      await svc.handleMessageForTesting('totally not json\n');
      final screen = _visibleContent(svc);
      expect(screen, isEmpty);
      expect(svc.lastSyncRecoveryReasonForTesting, isNotNull);
    });

    test('truncated JSON does NOT reach the terminal', () async {
      await svc.handleMessageForTesting(
        '{"seq":7,"type":"pty","payload":"dGVzdA',
      );
      final screen = _visibleContent(svc);
      expect(screen, isEmpty);
    });

    test('handshake messages are silently ignored', () async {
      await svc.handleMessageForTesting('{"type":"handshake","hmac":"xx"}');
      await svc.handleMessageForTesting('{"type":"boot"}');
      final screen = _visibleContent(svc);
      expect(screen, isEmpty);
    });

    test('unknown envelope type is silently dropped (no leak)', () async {
      await svc.handleMessageForTesting(
        '{"type":"future_thing","seq":1,"payload":"x"}',
      );
      final screen = _visibleContent(svc);
      expect(screen, isEmpty);
    });

    test('pty envelope without session_id triggers sync recovery, not write',
        () async {
      await svc.handleMessageForTesting(
        '{"type":"pty","seq":1,"payload":"ZGF0YQ=="}',
      );
      final screen = _visibleContent(svc);
      expect(screen, isEmpty);
      expect(svc.lastSyncRecoveryReasonForTesting, isNotNull);
    });
  });
}
