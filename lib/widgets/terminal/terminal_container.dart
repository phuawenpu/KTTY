import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../../state/viewport_state.dart';

class TerminalContainer extends StatefulWidget {
  final Terminal terminal;
  final TerminalController? controller;

  const TerminalContainer({super.key, required this.terminal, this.controller});

  @override
  State<TerminalContainer> createState() => _TerminalContainerState();
}

class _TerminalContainerState extends State<TerminalContainer> {
  double? _fontSizeOverride;
  bool _autoSized = false;

  static const double _minFontSize = 6.0;
  static const double _maxFontSize = 24.0;
  static const double _fontStep = 1.0;
  static const double _defaultFontSize = 14.0;
  // Approximate ratio: monospace char width ≈ 0.6 * fontSize
  static const double _charWidthRatio = 0.6;
  static const int _targetMinCols = 80;

  double _autoFontSize(double availableWidth) {
    // Calculate font size that fits _targetMinCols in the available width.
    final ideal = availableWidth / (_targetMinCols * _charWidthRatio);
    return ideal.clamp(_minFontSize, _maxFontSize);
  }

  void _zoomIn() {
    setState(() {
      _fontSizeOverride = ((_fontSizeOverride ?? _defaultFontSize) + _fontStep)
          .clamp(_minFontSize, _maxFontSize);
    });
  }

  void _zoomOut() {
    setState(() {
      _fontSizeOverride = ((_fontSizeOverride ?? _defaultFontSize) - _fontStep)
          .clamp(_minFontSize, _maxFontSize);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isResizing = context.watch<ViewportState>().isResizing;

    return Stack(
      children: [
        // Terminal view — auto-sizes font to fit 80 columns on first layout.
        Container(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Auto-size font on first layout to fit 80 cols.
              if (!_autoSized && _fontSizeOverride == null) {
                _autoSized = true;
                _fontSizeOverride = _autoFontSize(constraints.maxWidth);
              }
              final fontSize = _fontSizeOverride ?? _defaultFontSize;
              return TerminalView(
                widget.terminal,
                controller: widget.controller,
                readOnly: false,
                hardwareKeyboardOnly: true,
                autofocus: false,
                autoResize: true,
                textStyle: TerminalStyle(
                  fontSize: fontSize,
                  fontFamily: 'monospace',
                ),
              );
            },
          ),
        ),
        // Zoom controls — top right
        Positioned(
          top: 4,
          right: 4,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildZoomButton(Icons.remove, _zoomOut),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '${(_fontSizeOverride ?? _defaultFontSize).round()}',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
              ),
              _buildZoomButton(Icons.add, _zoomIn),
            ],
          ),
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

  Widget _buildZoomButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: const Color(0xFF2A2A4A).withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, color: Colors.white54, size: 14),
        ),
      ),
    );
  }
}
