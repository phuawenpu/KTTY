import 'package:flutter/material.dart';

class ControlCluster extends StatelessWidget {
  final bool ctrlActive;
  final bool capsLock;
  final VoidCallback onCtrlToggle;
  final VoidCallback onCapsLockToggle;
  final ValueChanged<String> onKeyPressed;
  final VoidCallback? onHideKeyboard;

  const ControlCluster({
    super.key,
    required this.ctrlActive,
    required this.capsLock,
    required this.onCtrlToggle,
    required this.onCapsLockToggle,
    required this.onKeyPressed,
    this.onHideKeyboard,
  });

  Widget _buildModifierKey(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF0F3460) : const Color(0xFF2A2A4A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? Colors.blueAccent : const Color(0xFF4A4A6A),
              width: active ? 1.0 : 0.5,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: active ? Colors.blueAccent : Colors.white70,
                fontSize: 13.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKey(String label, String value) {
    return Expanded(
      child: GestureDetector(
        onTap: () => onKeyPressed(value),
        child: Container(
          margin: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A4A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: const Color(0xFF4A4A6A),
              width: 0.5,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArrowKey(String label, String escSeq, IconData icon) {
    return Expanded(
      child: GestureDetector(
        onTap: () => onKeyPressed(escSeq),
        child: Container(
          margin: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A4A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: const Color(0xFF4A4A6A),
              width: 0.5,
            ),
          ),
          child: Center(
            child: Icon(icon, color: Colors.white70, size: 15.9),
          ),
        ),
      ),
    );
  }

  Widget _buildIconKey(IconData icon, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(3.0),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A4A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: const Color(0xFF4A4A6A),
              width: 0.5,
            ),
          ),
          child: Center(
            child: Icon(icon, color: Colors.white70, size: 15.9),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          _buildKey('Tab', '\t'),
          _buildKey('Esc', '\x1b'),
          _buildModifierKey('Ctrl', ctrlActive, onCtrlToggle),
          // Single CAPS key replaces the previous ab/Aa pair. Tapping it
          // toggles caps lock; the bottom-row up-arrow on the qwerty layer
          // is still the one-shot shift if you only need a single capital.
          _buildModifierKey('CAPS', capsLock, onCapsLockToggle),
          _buildArrowKey('Up', '\x1b[A', Icons.arrow_upward),
          _buildArrowKey('Down', '\x1b[B', Icons.arrow_downward),
          _buildArrowKey('Left', '\x1b[D', Icons.arrow_back),
          _buildArrowKey('Right', '\x1b[C', Icons.arrow_forward),
          // Keyboard-hide button moved up from the toolbar row to use the
          // slot freed by collapsing ab/Aa into a single CAPS key.
          if (onHideKeyboard != null)
            _buildIconKey(Icons.keyboard_hide, onHideKeyboard!),
        ],
      ),
    );
  }
}
