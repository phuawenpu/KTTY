import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/viewport_mode.dart';
import '../../state/keyboard_state.dart';

class ClipboardButtons extends StatelessWidget {
  final ViewportMode mode;
  final String Function() onGetSelectedText;
  final ValueChanged<String>? onPaste;

  const ClipboardButtons({
    super.key,
    required this.mode,
    required this.onGetSelectedText,
    this.onPaste,
  });

  void _onMarkStart(BuildContext context) {
    // Toggle marking mode. The user can then tap in the terminal to set
    // the selection start, or use arrow keys to position the cursor.
    // The xterm TerminalView handles tap-to-select natively.
    final ks = context.read<KeyboardState>();
    ks.setMarking(!ks.marking);
  }

  void _onMarkEnd(BuildContext context) {
    final text = onGetSelectedText();
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
    // Exit marking mode
    context.read<KeyboardState>().setMarking(false);
  }

  void _onCopy() {
    final text = onGetSelectedText();
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
  }

  void _onPaste() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.isNotEmpty) {
      onPaste?.call(data.text!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final marking = context.watch<KeyboardState>().marking;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          marking ? Icons.location_on : Icons.start,
          marking ? 'Cancel Mark' : 'Mark Start',
          () => _onMarkStart(context),
          active: marking,
        ),
        _buildIconButton(Icons.last_page, 'Mark End',
            () => _onMarkEnd(context)),
        _buildIconButton(Icons.copy, 'Copy', _onCopy),
        if (mode == ViewportMode.portrait)
          _buildIconButton(Icons.paste, 'Paste', _onPaste),
      ],
    );
  }

  Widget _buildIconButton(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Icon(
              icon,
              color: active ? Colors.blueAccent : Colors.white54,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}
