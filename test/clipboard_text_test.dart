// Tests for lib/services/terminal/clipboard_text.dart.
//
// What we're guarding against:
//
// 1. A long URL selected out of a TUI (Claude Code, vim) used to be
//    copied with phantom `\n`s wherever the visual row wrapped — TUIs
//    draw rows with cursor positioning instead of relying on xterm's
//    auto-wrap, so `line.isWrapped` is never set and xterm's stock
//    `buffer.getText()` inserts a newline between rows. The visual-
//    wrap heuristic in extractSelectionText collapses those back into
//    one line.
// 2. Pasting multi-line text with the on-screen keyboard used to send
//    raw `\n`s into the PTY, so vim autoindented every line and shells
//    executed each line on arrival. encodeForPaste fixes that by
//    wrapping with bracketed-paste escape codes when the remote app
//    has enabled DECSET 2004.
//
// Both paths are exercised by driving a detached xterm.dart Terminal
// from the test and asserting on bytes/strings, not pixels.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:ktty/services/terminal/clipboard_text.dart';

/// Spin up a detached Terminal at a known size and feed it [input].
/// Returns the terminal; use its `buffer` / `selection` directly.
Terminal _term(int cols, int rows, {String input = ''}) {
  final t = Terminal(maxLines: 200);
  t.resize(cols, rows);
  if (input.isNotEmpty) t.write(input);
  return t;
}

/// Whole-viewport selection (absolute buffer rows).
BufferRange _selectAll(Terminal t) {
  final buffer = t.buffer;
  return BufferRangeLine(
    CellOffset(0, buffer.height - buffer.viewHeight),
    CellOffset(t.viewWidth - 1, buffer.height - 1),
  );
}

void main() {
  group('extractSelectionText', () {
    test('returns empty string for null selection', () {
      final t = _term(20, 5);
      expect(extractSelectionText(t, null), '');
    });

    test('returns empty string for collapsed selection', () {
      final t = _term(20, 5);
      final collapsed = BufferRangeLine(
        const CellOffset(3, 0),
        const CellOffset(3, 0),
      );
      expect(extractSelectionText(t, collapsed), '');
    });

    test('strips trailing cell padding on a single-line selection', () {
      final t = _term(20, 5, input: 'hello');
      // Select the whole first visible row.
      final buffer = t.buffer;
      final row0 = buffer.height - buffer.viewHeight;
      final sel = BufferRangeLine(
        CellOffset(0, row0),
        CellOffset(19, row0),
      );
      final out = extractSelectionText(t, sel);
      expect(out, 'hello');
      expect(out.contains(' '), isFalse);
    });

    test('keeps the newline between two genuinely separate rows', () {
      // Two short lines printed normally; the auto-wrap isWrapped flag
      // is NOT set because neither line filled the viewport width.
      final t = _term(20, 5, input: 'foo\r\nbar');
      final out = extractSelectionText(t, _selectAll(t));
      expect(out, contains('foo\nbar'));
      expect(out.contains('\r'), isFalse);
    });

    test('collapses a naturally-wrapped long line (isWrapped path)', () {
      // 25 "a"s into a 10-wide terminal → auto-wraps across three rows,
      // with the 2nd and 3rd rows carrying isWrapped = true. xterm's
      // own getText already handles this, but we verify we don't
      // regress it.
      final t = _term(10, 5, input: 'a' * 25);
      final out = extractSelectionText(t, _selectAll(t));
      expect(out, 'a' * 25);
    });

    test('collapses a TUI-drawn wrap via the heuristic (isWrapped=false)', () {
      // Simulate what Claude Code / vim do: move cursor to each row
      // explicitly and draw the row contents. isWrapped stays false on
      // the 2nd row even though visually it is the continuation of a
      // URL. The heuristic (prev row visibly full + this row starts at
      // col 0) should suppress the inter-row newline.
      final t = _term(10, 5);
      t.write('\x1b[H'); // cursor home (row 1 col 1)
      t.write('https://e'); // 9 chars, row 1 col 1..9
      t.write('x'); // fills row 1 fully (10 chars, no explicit wrap)
      t.write('\x1b[2;1H'); // jump cursor to row 2 col 1 — key TUI move
      t.write('ample.com');
      final out = extractSelectionText(t, _selectAll(t));
      expect(
        out,
        contains('https://example.com'),
        reason:
            'Long URL drawn across two TUI rows should come back whole',
      );
      expect(
        out.contains('https://ex\nample.com'),
        isFalse,
        reason: 'Heuristic failed: URL still split by a newline',
      );
    });

    test('strips \\r that sneaks through the buffer', () {
      // Defense-in-depth: force a buffer row that somehow contains a
      // literal \r (cursor return without line feed) and verify it
      // doesn't land on the clipboard. xterm treats CR as "cursor to
      // column 0", so write "abc\rX" → row becomes "Xbc". Then select
      // → "Xbc", no CR. This just guards the final strip pass.
      final t = _term(10, 5, input: 'abc\rX');
      final out = extractSelectionText(t, _selectAll(t));
      expect(out.contains('\r'), isFalse);
    });
  });

  group('encodeForPaste', () {
    test('passes plain text through when bracketed paste is off', () {
      final t = _term(80, 24);
      expect(t.bracketedPasteMode, isFalse,
          reason: 'Default xterm.dart terminal should be non-bracketed');
      expect(encodeForPaste(t, 'hello world'), 'hello world');
    });

    test('normalizes CRLF to LF even without bracketed paste', () {
      final t = _term(80, 24);
      expect(encodeForPaste(t, 'line1\r\nline2\r\nline3'),
          'line1\nline2\nline3');
    });

    test('normalizes lone CR to LF even without bracketed paste', () {
      final t = _term(80, 24);
      expect(encodeForPaste(t, 'line1\rline2'), 'line1\nline2');
    });

    test('wraps in bracketed paste markers when the remote enables 2004', () {
      final t = _term(80, 24);
      // DECSET 2004 — "set bracketed paste mode". Any modern shell
      // (.bashrc / zsh default), vim, tmux, and Claude Code all emit
      // this when they attach to a TTY.
      t.write('\x1b[?2004h');
      expect(t.bracketedPasteMode, isTrue);
      final payload = encodeForPaste(t, 'hello');
      expect(payload, '\x1b[200~hello\x1b[201~');
    });

    test('bracketed paste still normalizes embedded CR/CRLF', () {
      // This is the bug vim users feel most: paste three lines of
      // code → vim autoindents because the \r\n is re-emitted by the
      // shell. Normalizing the clipboard payload to pure \n, inside
      // the bracketed-paste markers, lets vim treat the whole thing
      // as a single paste event.
      final t = _term(80, 24);
      t.write('\x1b[?2004h');
      final payload = encodeForPaste(t, 'a\r\nb\rc');
      expect(payload, '\x1b[200~a\nb\nc\x1b[201~');
    });

    test('disabling bracketed paste (2004l) returns to plain passthrough', () {
      final t = _term(80, 24);
      t.write('\x1b[?2004h');
      expect(t.bracketedPasteMode, isTrue);
      t.write('\x1b[?2004l');
      expect(t.bracketedPasteMode, isFalse);
      expect(encodeForPaste(t, 'hi'), 'hi');
    });
  });
}
