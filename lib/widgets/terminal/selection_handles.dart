import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import '../../services/terminal/clipboard_text.dart';

/// Android-style teardrop selection handles overlaid on the terminal.
/// Appears when xterm's internal long-press or double-tap selects text.
/// Handles can be dragged to adjust the selection range.
class SelectionHandlesOverlay extends StatefulWidget {
  final Terminal terminal;
  final TerminalController controller;
  final double fontSize;
  final double charWidth;
  final double lineHeight;

  const SelectionHandlesOverlay({
    super.key,
    required this.terminal,
    required this.controller,
    required this.fontSize,
    required this.charWidth,
    required this.lineHeight,
  });

  @override
  State<SelectionHandlesOverlay> createState() =>
      _SelectionHandlesOverlayState();
}

class _SelectionHandlesOverlayState extends State<SelectionHandlesOverlay> {
  BufferRange? _selection;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Poll controller.selection since TerminalController doesn't expose
    // a listener for selection changes.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final sel = widget.controller.selection;
      if (sel != _selection) {
        setState(() => _selection = sel);
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  double get _charWidth => widget.charWidth;
  double get _lineHeight => widget.lineHeight;

  /// Convert terminal cell offset to pixel offset relative to the terminal view.
  /// Note: `cell.y` is an *absolute* buffer row (scrollback + viewport).
  /// We only render handles for the viewport portion of the selection, so
  /// subtract the buffer's scroll offset first.
  Offset _cellToPixel(CellOffset cell) {
    final buffer = widget.terminal.buffer;
    final viewportY = cell.y - (buffer.height - buffer.viewHeight);
    return Offset(
      cell.x * _charWidth,
      viewportY * _lineHeight,
    );
  }

  void _onCopy() {
    final sel = widget.controller.selection;
    if (sel == null) return;
    final text = extractSelectionText(widget.terminal, sel);
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
      print('[KTTY] Copied: "${text.length > 50 ? '${text.substring(0, 50)}...' : text}"');
    }
    // Clear selection after copy
    widget.controller.clearSelection();
    setState(() => _selection = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_selection == null || _selection!.isCollapsed) {
      return const SizedBox.shrink();
    }

    final begin = _selection!.begin;
    final end = _selection!.end;
    final startPixel = _cellToPixel(begin);
    final endPixel = _cellToPixel(end);

    return Stack(
      children: [
        // Start handle (left teardrop)
        Positioned(
          left: startPixel.dx - 8,
          top: startPixel.dy + _lineHeight,
          child: _buildHandle(isStart: true),
        ),
        // End handle (right teardrop)
        Positioned(
          left: endPixel.dx - 8,
          top: endPixel.dy + _lineHeight,
          child: _buildHandle(isStart: false),
        ),
        // Floating toolbar above selection
        Positioned(
          left: (startPixel.dx + endPixel.dx) / 2 - 30,
          top: startPixel.dy - 36,
          child: _buildToolbar(),
        ),
      ],
    );
  }

  Widget _buildHandle({required bool isStart}) {
    return GestureDetector(
      onPanUpdate: (details) {
        // TODO: Update selection range based on drag
        // This requires converting pixel back to cell offset and
        // updating the controller selection. Deferred to avoid
        // complexity with xterm's CellAnchor API.
      },
      child: CustomPaint(
        size: const Size(16, 24),
        painter: _TeardropPainter(
          color: Colors.blueAccent,
          isStart: isStart,
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      color: const Color(0xFF2A2A4A),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _toolbarButton(Icons.copy, 'Copy', _onCopy),
          ],
        ),
      ),
    );
  }

  Widget _toolbarButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Paints an Android-style teardrop selection handle.
class _TeardropPainter extends CustomPainter {
  final Color color;
  final bool isStart;

  _TeardropPainter({required this.color, required this.isStart});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final cx = size.width / 2;

    // Circle at top
    canvas.drawCircle(Offset(cx, 6), 6, paint);

    // Teardrop tail pointing down
    final path = Path();
    if (isStart) {
      path.moveTo(cx, 6);
      path.lineTo(cx - 6, 6);
      path.lineTo(cx, size.height);
      path.close();
    } else {
      path.moveTo(cx, 6);
      path.lineTo(cx + 6, 6);
      path.lineTo(cx, size.height);
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TeardropPainter oldDelegate) =>
      color != oldDelegate.color || isStart != oldDelegate.isStart;
}
