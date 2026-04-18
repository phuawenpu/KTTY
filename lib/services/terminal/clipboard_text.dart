import 'package:xterm/xterm.dart';

/// Clipboard-safe text helpers for KTTY's terminal panel.
///
/// Two independent bugs motivated this file:
///
/// 1. **Copy introduces phantom newlines.** xterm.dart's
///    `buffer.getText(range)` inserts a `\n` between rows whenever the
///    next row is not marked `isWrapped`. Modern TUI apps (Claude Code,
///    tmux, vim) draw each visible row with explicit cursor positioning
///    (`CSI row;col H`) instead of relying on terminal auto-wrap, so the
///    `isWrapped` flag is never set even when what the user sees is a
///    single logical line wrapped across rows. Selecting a long URL
///    from such a TUI therefore comes out of the clipboard broken by
///    embedded newlines.
///
/// 2. **Paste clobbers the TUI.** Pressing the on-screen keyboard's
///    Paste button fires text straight at the PTY as if the user had
///    typed it. vim's autoindent fires per line, shells execute each
///    line as it arrives, and Claude Code's input box sees multiple
///    Enters. Every sane modern TUI enables *bracketed paste mode*
///    (DECSET 2004) precisely so it can distinguish a paste from
///    typing; we just weren't wrapping the paste in the escape
///    sequences it advertises.
///
/// Both fixes are applied here. The helpers are pure(ish) — they take
/// an xterm.dart [Terminal] so tests can drive them by writing ANSI
/// straight into a detached terminal instead of needing the whole WS
/// plumbing.

/// Extract the text covered by [selection] in a form suitable for the
/// system clipboard.
///
/// The result differs from `terminal.buffer.getText(selection)` in three
/// ways:
///
///  - `\r` characters are stripped unconditionally. They never belong
///    on the clipboard (line ends on the OS clipboard are `\n`-only on
///    every platform we target) and when they do sneak through they
///    corrupt downstream paste targets (URL bars, chat boxes, etc.).
///  - Each row's trailing cell padding (the spaces xterm pads blank
///    cells with) is stripped. Otherwise every copied line carries a
///    long run of spaces out to the viewport edge.
///  - The newline between two adjacent rows is suppressed when the
///    previous row's visible content reached the last column **and**
///    this row starts at column 0. That's the visual-wrap heuristic:
///    xterm.dart's `isWrapped` flag is authoritative for naturally
///    wrapped text but is never set by TUI-driven cursor positioning,
///    so we add this second signal on top.
///
/// Returns an empty string when [selection] is null or collapsed.
String extractSelectionText(Terminal terminal, BufferRange? selection) {
  if (selection == null || selection.isCollapsed) return '';
  final normalized = selection.normalized;
  final segments = normalized.toSegments().toList(growable: false);
  final lines = terminal.buffer.lines;
  final height = terminal.buffer.height;
  final viewWidth = terminal.viewWidth;

  final out = StringBuffer();
  String? prevRaw;
  var anyContent = false;

  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    if (seg.line < 0 || seg.line >= height) continue;
    final line = lines[seg.line];
    final raw = line.getText(seg.start, seg.end);
    final stripped = _rstripSpaces(raw);

    if (anyContent) {
      // Skip the inter-row newline when:
      //   - xterm has flagged this row as a wrap of the previous
      //     (auto-wrapped text — the `isWrapped` path), OR
      //   - the previous row's visible content filled the viewport and
      //     this row's selection starts at column 0 (the TUI-drawn
      //     wrap heuristic — Claude Code / vim / tmux drive each row
      //     with explicit CUP and never set isWrapped).
      final thisStartsAtZero = (seg.start ?? 0) == 0;
      final prevVisiblyFull = prevRaw != null &&
          _rstripSpaces(prevRaw).length >= viewWidth;
      final heuristicWrap = prevVisiblyFull && thisStartsAtZero;
      if (!(line.isWrapped || heuristicWrap)) {
        out.write('\n');
      }
    }

    out.write(stripped);
    prevRaw = raw;
    if (stripped.isNotEmpty) anyContent = true;
  }

  // A dragged selection almost always overshoots the content by a row
  // or two of blank cells; trim the resulting trailing newlines so the
  // clipboard doesn't get pillowed with empty lines. We deliberately
  // don't trim leading newlines — someone selecting a block with a
  // leading blank line likely wants it.
  var result = _stripCarriageReturns(out.toString());
  while (result.endsWith('\n')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/// Encode [text] for injection into the PTY as a paste operation.
///
/// Line endings are normalized (`\r\n` → `\n`, lone `\r` → `\n`) so that
/// clipboard payloads copied from Windows or old macOS sources don't
/// double up on newlines at the remote end.
///
/// When the remote app has enabled bracketed paste mode (DECSET 2004 —
/// xterm.dart tracks this as [Terminal.bracketedPasteMode]), the text
/// is wrapped with `ESC [ 200 ~ ... ESC [ 201 ~` so vim stays out of
/// autoindent, bash highlights-but-does-not-execute, and Claude Code
/// sees the whole thing as a single input event.
///
/// When bracketed paste is not enabled, the normalized text is returned
/// on its own — the caller will ship it through the same channel as
/// regular keystrokes.
String encodeForPaste(Terminal terminal, String text) {
  final normalized = _normalizeLineEndings(text);
  if (terminal.bracketedPasteMode) {
    return '\x1b[200~$normalized\x1b[201~';
  }
  return normalized;
}

String _rstripSpaces(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  return end == s.length ? s : s.substring(0, end);
}

String _stripCarriageReturns(String s) {
  if (!s.contains('\r')) return s;
  return s.replaceAll('\r', '');
}

String _normalizeLineEndings(String s) {
  if (!s.contains('\r')) return s;
  return s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
