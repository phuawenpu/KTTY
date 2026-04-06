import 'package:flutter/material.dart';
import 'key_definitions.dart';

class KeyButton extends StatefulWidget {
  final KeyDef keyDef;
  final bool isUpperCase;
  final bool ctrlActive;
  final ValueChanged<String> onKeyPressed;

  const KeyButton({
    super.key,
    required this.keyDef,
    required this.isUpperCase,
    required this.ctrlActive,
    required this.onKeyPressed,
  });

  @override
  State<KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<KeyButton> {
  bool _pressed = false;
  Offset? _panStart;

  String get _displayLabel {
    final label = widget.keyDef.label;
    if (widget.isUpperCase && label.length == 1) {
      return label.toUpperCase();
    }
    return label;
  }

  void _handleTap() {
    String value = widget.keyDef.value;

    // Apply uppercase if shift/caps active and it's a letter
    if (widget.isUpperCase && value.length == 1) {
      final code = value.codeUnitAt(0);
      if (code >= 97 && code <= 122) {
        value = value.toUpperCase();
      }
    }

    // Apply ctrl modifier if active
    if (widget.ctrlActive && value.length == 1) {
      final code = value.toUpperCase().codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        value = String.fromCharCode(code - 64);
      }
    }

    widget.onKeyPressed(value);
  }

  void _handleSwipe(Offset delta) {
    const threshold = 20.0;
    final dx = delta.dx;
    final dy = delta.dy;

    if (dx.abs() < threshold && dy.abs() < threshold) {
      _handleTap();
      return;
    }

    String? swipeValue;
    if (dy.abs() > dx.abs()) {
      // Vertical swipe
      swipeValue = dy < 0
          ? widget.keyDef.swipeUpValue
          : widget.keyDef.swipeDownValue;
    } else {
      // Horizontal swipe
      swipeValue = dx < 0
          ? widget.keyDef.swipeLeftValue
          : widget.keyDef.swipeRightValue;
    }

    widget.onKeyPressed(swipeValue ?? widget.keyDef.value);
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: (widget.keyDef.flex * 10).round(),
      child: GestureDetector(
        onPanStart: (details) {
          _panStart = details.localPosition;
          setState(() => _pressed = true);
        },
        onPanEnd: (details) {
          if (_panStart != null) {
            final delta = details.velocity.pixelsPerSecond;
            if (delta.dx.abs() < 50 && delta.dy.abs() < 50) {
              _handleTap();
            } else {
              _handleSwipe(Offset(delta.dx, delta.dy));
            }
          }
          setState(() => _pressed = false);
          _panStart = null;
        },
        onPanCancel: () {
          setState(() => _pressed = false);
          _panStart = null;
        },
        onTap: _handleTap,
        child: Container(
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: _pressed
                ? const Color(0xFF3A3A5C)
                : const Color(0xFF2A2A4A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: const Color(0xFF4A4A6A),
              width: 0.5,
            ),
          ),
          child: Center(
            child: Text(
              _displayLabel,
              style: TextStyle(
                color: Colors.white,
                fontSize: widget.keyDef.label.length > 2 ? 10 : 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
