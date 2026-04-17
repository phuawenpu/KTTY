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
  final bool hardwareKeyboardOnly;
  // Pinch lifecycle hooks so the TerminalService can hold off PTY
  // resize messages while the user is actively pinching. Optional:
  // container works standalone (e.g. in widget tests) if unset.
  final VoidCallback? onPinchStart;
  final VoidCallback? onPinchEnd;

  const TerminalContainer({
    super.key,
    required this.terminal,
    this.controller,
    this.onFontSizeChanged,
    this.onWordTapped,
    this.hardwareKeyboardOnly = true,
    this.onPinchStart,
    this.onPinchEnd,
  });

  @override
  State<TerminalContainer> createState() => TerminalContainerState();
}

class TerminalContainerState extends State<TerminalContainer> {
  double _fontSize = _defaultFontSize;
  bool _autoSized = false;
  double _pinchBaseFontSize = _defaultFontSize;
  int _pointerCount = 0;
  bool _pinching = false;
  DateTime? _lastTapTime;
  CellOffset? _lastTapCell;
  // Live font-size broadcast for tiny UI elements (e.g. the AppBar
  // size readout) that want to rebuild on every pinch frame without
  // pulling the whole TerminalScreen into a setState cycle.
  final ValueNotifier<double> fontSizeNotifier =
      ValueNotifier<double>(_defaultFontSize);

  static const double _minFontSize = 6.0;
  static const double _maxFontSize = 24.0;
  static const double _defaultFontSize = 14.0;
  static const double _charWidthRatio = 0.6;
  static const int _targetMinCols = 80;
  // Ignore sub-pixel pinch noise so we don't rebuild every frame for
  // imperceptible changes. 0.5 px ≈ one render hint; below that, skip.
  static const double _pinchEpsilon = 0.5;

  double get fontSize => _fontSize;
  bool get isPinching => _pinching;

  double _autoFontSize(double availableWidth) {
    final ideal = availableWidth / (_targetMinCols * _charWidthRatio);
    return ideal.clamp(_minFontSize, _maxFontSize);
  }

  void zoomIn() {
    _setFontSize(_fontSize + 1.0, notify: true);
  }

  void zoomOut() {
    _setFontSize(_fontSize - 1.0, notify: true);
  }

  /// Update local font size. [notify] controls whether the parent is
  /// informed — we pass `false` per-frame during pinch (to avoid
  /// rebuilding the whole TerminalScreen 60×/s) and `true` on scale-end,
  /// explicit zoom buttons, and auto-sizing.
  void _setFontSize(double next, {required bool notify}) {
    final clamped = next.clamp(_minFontSize, _maxFontSize);
    if (clamped == _fontSize) {
      if (notify) widget.onFontSizeChanged?.call(_fontSize);
      return;
    }
    setState(() => _fontSize = clamped);
    fontSizeNotifier.value = clamped;
    if (notify) widget.onFontSizeChanged?.call(_fontSize);
  }

  @override
  void dispose() {
    fontSizeNotifier.dispose();
    super.dispose();
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
                fontSizeNotifier.value = _fontSize;
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
                      _pinching = true;
                      widget.onPinchStart?.call();
                    }
                  },
                  onScaleUpdate: (details) {
                    if (_pointerCount < 2) return;
                    final next = _pinchBaseFontSize * details.scale;
                    // During pinch we update the container but do NOT
                    // notify the parent — that would rebuild the whole
                    // TerminalScreen every frame. Parent sees the final
                    // value on scale-end.
                    if ((next - _fontSize).abs() < _pinchEpsilon) return;
                    _setFontSize(next, notify: false);
                  },
                  onScaleEnd: (_) {
                    if (_pinching) {
                      _pinching = false;
                      widget.onFontSizeChanged?.call(_fontSize);
                      widget.onPinchEnd?.call();
                    }
                  },
                  child: TerminalView(
                    widget.terminal,
                    controller: widget.controller,
                    readOnly: false,
                    hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
                    autofocus: false,
                    autoResize: true,
                    onTapUp: _handleTapUp,
                    textStyle: TerminalStyle(
                      fontSize: _fontSize,
                      fontFamily: 'RobotoMono',
                      fontFamilyFallback: const [
                        'Roboto Mono',
                        'Consolas',
                        'Menlo',
                        'Liberation Mono',
                        'monospace',
                      ],
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
