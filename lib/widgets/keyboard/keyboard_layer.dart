import 'package:flutter/material.dart';
import 'key_definitions.dart';
import 'key_button.dart';

class KeyboardLayer extends StatelessWidget {
  final List<List<KeyDef>> rows;
  final bool isUpperCase;
  final bool ctrlActive;
  final ValueChanged<String> onKeyPressed;

  const KeyboardLayer({
    super.key,
    required this.rows,
    required this.isUpperCase,
    required this.ctrlActive,
    required this.onKeyPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: rows.map((row) {
        return Expanded(
          child: Row(
            children: row.map((keyDef) {
              return KeyButton(
                keyDef: keyDef,
                isUpperCase: isUpperCase,
                ctrlActive: ctrlActive,
                onKeyPressed: onKeyPressed,
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}
