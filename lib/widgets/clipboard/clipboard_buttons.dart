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

  void _onMarkStart() {
    // Triggers mark start — future integration with terminal selection
  }

  void _onMarkEnd() {
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
    return Positioned(
      right: 8,
      bottom: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildButton('Mark\nStart', _onMarkStart),
          const SizedBox(height: 4),
          _buildButton('Mark\nEnd', _onMarkEnd),
          if (mode == ViewportMode.portrait) ...[
            const SizedBox(height: 4),
            _buildButton('Paste', _onPaste),
          ],
        ],
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A4A).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF4A4A6A)),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 9,
          ),
        ),
      ),
    );
  }
}
