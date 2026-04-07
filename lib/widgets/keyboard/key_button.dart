import 'package:flutter/material.dart';
import 'key_definitions.dart';

class KeyButton extends StatelessWidget {
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

  String get _displayLabel {
    final label = keyDef.label;
    if (isUpperCase && label.length == 1) {
      return label.toUpperCase();
    }
    return label;
  }

  void _handleTap() {
    String value = keyDef.value;

    if (isUpperCase && value.length == 1) {
      final code = value.codeUnitAt(0);
      if (code >= 97 && code <= 122) {
        value = value.toUpperCase();
      }
    }

    if (ctrlActive && value.length == 1) {
      final code = value.toUpperCase().codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        value = String.fromCharCode(code - 64);
      }
    }

    onKeyPressed(value);
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: (keyDef.flex * 10).round(),
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        child: Material(
          color: const Color(0xFF2A2A4A),
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: _handleTap,
            borderRadius: BorderRadius.circular(5),
            splashColor: const Color(0xFF4A4A6A),
            highlightColor: const Color(0xFF3A3A5C),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
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
                    fontSize: keyDef.label.length > 2 ? 10 : 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
