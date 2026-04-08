import 'package:flutter/material.dart';
import 'key_definitions.dart';
import 'key_button.dart';

class KeyboardLayer extends StatelessWidget {
  final List<List<KeyDef>> rows;
  final bool isUpperCase;
  final bool ctrlActive;
  final ValueChanged<String> onKeyPressed;
  final VoidCallback? onSpaceLongPress;
  final bool spaceLongPressActive;

  const KeyboardLayer({
    super.key,
    required this.rows,
    required this.isUpperCase,
    required this.ctrlActive,
    required this.onKeyPressed,
    this.onSpaceLongPress,
    this.spaceLongPressActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: rows.map((row) {
        return Expanded(
          child: Row(
            children: row.map((keyDef) {
              final isSpace = keyDef.label == 'Space';
              return KeyButton(
                keyDef: keyDef,
                isUpperCase: isUpperCase,
                ctrlActive: ctrlActive,
                onKeyPressed: onKeyPressed,
                onLongPress: isSpace ? onSpaceLongPress : null,
                longPressActive: isSpace && spaceLongPressActive,
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}
