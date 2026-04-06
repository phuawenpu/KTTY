import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../../state/viewport_state.dart';

class TerminalContainer extends StatelessWidget {
  final Terminal terminal;

  const TerminalContainer({super.key, required this.terminal});

  @override
  Widget build(BuildContext context) {
    final isResizing = context.watch<ViewportState>().isResizing;

    return Stack(
      children: [
        Container(
          color: Colors.black,
          child: TerminalView(
            terminal,
            readOnly: true,
            autofocus: false,
            textStyle: const TerminalStyle(
              fontSize: 13.5,
              fontFamily: 'monospace',
            ),
          ),
        ),
        if (isResizing)
          Container(
            color: Colors.black.withValues(alpha: 0.7),
            child: const Center(
              child: Text(
                'Resizing...',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
