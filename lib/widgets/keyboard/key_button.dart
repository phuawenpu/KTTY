import 'package:flutter/material.dart';
import 'key_definitions.dart';

class KeyButton extends StatelessWidget {
  final KeyDef keyDef;
  final bool isUpperCase;
  final bool ctrlActive;
  final ValueChanged<String> onKeyPressed;
  final VoidCallback? onLongPress;
  final bool longPressActive;

  const KeyButton({
    super.key,
    required this.keyDef,
    required this.isUpperCase,
    required this.ctrlActive,
    required this.onKeyPressed,
    this.onLongPress,
    this.longPressActive = false,
  });

  String get _displayLabel {
    final label = keyDef.label;
    if (label.length == 1) {
      return isUpperCase ? label.toUpperCase() : label.toLowerCase();
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
        padding: const EdgeInsets.all(2.25),
        child: Material(
          color: longPressActive ? const Color(0xFFE53935) : const Color(0xFF2A2A4A),
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            onTap: _handleTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(5),
            splashColor: const Color(0xFF4A4A6A),
            highlightColor: const Color(0xFF3A3A5C),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: longPressActive ? const Color(0xFFE53935) : const Color(0xFF4A4A6A),
                  width: 0.5,
                ),
              ),
              child: Center(
                child: longPressActive
                    ? const Icon(Icons.mic, color: Colors.white, size: 20)
                    : onLongPress != null
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _displayLabel,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: keyDef.label.length > 2 ? 13.8 : 19.1,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.mic_none, color: Colors.white38, size: 14),
                            ],
                          )
                        : Text(
                            _displayLabel,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: keyDef.label.length > 2 ? 13.8 : 19.1,
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
