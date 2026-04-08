import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../../state/viewport_state.dart';
import 'selection_handles.dart';

class TerminalContainer extends StatefulWidget {
  final Terminal terminal;
  final TerminalController? controller;
  final ValueChanged<double>? onFontSizeChanged;
  final ValueChanged<String>? onWordTapped;

  const TerminalContainer({
    super.key,
    required this.terminal,
    this.controller,
    this.onFontSizeChanged,
    this.onWordTapped,
  });

  @override
  State<TerminalContainer> createState() => TerminalContainerState();
}

class TerminalContainerState extends State<TerminalContainer> {
  double _fontSize = _defaultFontSize;
  bool _autoSized = false;
  double _pinchBaseFontSize = _defaultFontSize;
  int _pointerCount = 0;
  DateTime? _lastTapTime;
  CellOffset? _lastTapCell;

  static const double _minFontSize = 6.0;
  static const double _maxFontSize = 24.0;
  static const double _defaultFontSize = 14.0;
  static const double _charWidthRatio = 0.6;
  static const int _targetMinCols = 80;

  double get fontSize => _fontSize;

  double _autoFontSize(double availableWidth) {
    final ideal = availableWidth / (_targetMinCols * _charWidthRatio);
    return ideal.clamp(_minFontSize, _maxFontSize);
  }

  void zoomIn() {
    setState(() {
      _fontSize = (_fontSize + 1.0).clamp(_minFontSize, _maxFontSize);
    });
    widget.onFontSizeChanged?.call(_fontSize);
  }

  void zoomOut() {
    setState(() {
      _fontSize = (_fontSize - 1.0).clamp(_minFontSize, _maxFontSize);
    });
    widget.onFontSizeChanged?.call(_fontSize);
  }

  /// Extract word at given cell offset from terminal buffer.
  String? _wordAtCell(CellOffset cell) {
    final buffer = widget.terminal.buffer;
    final absRow = buffer.height - buffer.viewHeight + cell.y;
    if (absRow < 0 || absRow >= buffer.height) return null;

    final line = buffer.lines[absRow];
    final lineText = line.toString();
    if (lineText.isEmpty || cell.x >= lineText.length) return null;

    // Find word boundaries (whitespace-delimited)
    int start = cell.x;
    int end = cell.x;
    while (start > 0 && lineText[start - 1] != ' ') {
      start--;
    }
    while (end < lineText.length && lineText[end] != ' ') {
      end++;
    }

    final word = lineText.substring(start, end).trim();
    return word.isNotEmpty ? word : null;
  }

  void _handleTapUp(TapUpDetails details, CellOffset cell) {
    final now = DateTime.now();
    final isDoubleTap = _lastTapTime != null &&
        _lastTapCell != null &&
        now.difference(_lastTapTime!).inMilliseconds < 400 &&
        (cell.x - _lastTapCell!.x).abs() <= 2 &&
        cell.y == _lastTapCell!.y;

    if (isDoubleTap) {
      _lastTapTime = null;
      _lastTapCell = null;
      // xterm's internal double-tap handler fires selectWord synchronously
      // before our onTapUp. Read the selection after a microtask to ensure
      // xterm has processed the double-tap.
      Future.microtask(() {
        final selection = widget.controller?.selection;
        if (selection != null) {
          final word = widget.terminal.buffer.getText(selection).trim();
          if (word.isNotEmpty) {
            print('[KTTY] Double-tap captured word: "$word"');
            widget.onWordTapped?.call(word);
          }
        } else {
          // Fallback: extract word from buffer directly
          final word = _wordAtCell(cell);
          if (word != null) {
            print('[KTTY] Double-tap captured word (fallback): "$word"');
            widget.onWordTapped?.call(word);
          }
        }
      });
    } else {
      _lastTapTime = now;
      _lastTapCell = cell;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isResizing = context.watch<ViewportState>().isResizing;

    return Stack(
      children: [
        Container(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (!_autoSized) {
                _autoSized = true;
                _fontSize = _autoFontSize(constraints.maxWidth);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  widget.onFontSizeChanged?.call(_fontSize);
                });
              }
              return Listener(
                onPointerDown: (_) => _pointerCount++,
                onPointerUp: (_) => _pointerCount--,
                onPointerCancel: (_) => _pointerCount--,
                child: GestureDetector(
                  onScaleStart: (_) {
                    if (_pointerCount >= 2) {
                      _pinchBaseFontSize = _fontSize;
                    }
                  },
                  onScaleUpdate: (details) {
                    if (_pointerCount < 2) return;
                    setState(() {
                      _fontSize = (_pinchBaseFontSize * details.scale)
                          .clamp(_minFontSize, _maxFontSize);
                    });
                    widget.onFontSizeChanged?.call(_fontSize);
                  },
                  child: TerminalView(
                    widget.terminal,
                    controller: widget.controller,
                    readOnly: false,
                    hardwareKeyboardOnly: true,
                    autofocus: false,
                    autoResize: true,
                    onTapUp: _handleTapUp,
                    textStyle: TerminalStyle(
                      fontSize: _fontSize,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Selection handles overlay
        if (widget.controller != null)
          SelectionHandlesOverlay(
            terminal: widget.terminal,
            controller: widget.controller!,
            fontSize: _fontSize,
            charWidthRatio: _charWidthRatio,
          ),
        // Resize overlay
        if (isResizing)
          Container(
            color: Colors.black.withValues(alpha: 0.7),
            child: const Center(
              child: Text(
                'Resizing...',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 22,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
