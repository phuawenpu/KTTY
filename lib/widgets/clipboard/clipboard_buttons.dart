import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/viewport_mode.dart';

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

  void _onMarkStart() {}

  void _onMarkEnd() {
    final text = onGetSelectedText();
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(Icons.start, 'Mark Start', _onMarkStart),
        _buildIconButton(Icons.last_page, 'Mark End', _onMarkEnd),
        _buildIconButton(Icons.copy, 'Copy', _onCopy),
        if (mode == ViewportMode.portrait)
          _buildIconButton(Icons.paste, 'Paste', _onPaste),
      ],
    );
  }

  Widget _buildIconButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Icon(icon, color: Colors.white54, size: 16),
          ),
        ),
      ),
    );
  }
}
