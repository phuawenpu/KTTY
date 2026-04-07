import 'package:flutter/material.dart';

class ControlCluster extends StatelessWidget {
  final bool ctrlActive;
  final bool shiftActive;
  final bool capsLock;
  final VoidCallback onCtrlToggle;
  final VoidCallback onShiftToggle;
  final VoidCallback onCapsLockToggle;
  final ValueChanged<String> onKeyPressed;

  const ControlCluster({
    super.key,
    required this.ctrlActive,
    required this.shiftActive,
    required this.capsLock,
    required this.onCtrlToggle,
    required this.onShiftToggle,
    required this.onCapsLockToggle,
    required this.onKeyPressed,
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
                fontSize: 12,
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
                fontSize: 12,
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
            child: Icon(icon, color: Colors.white70, size: 14),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          _buildKey('Esc', '\x1b'),
          _buildKey('Tab', '\t'),
          _buildModifierKey('Ctrl', ctrlActive, onCtrlToggle),
          _buildModifierKey(shiftActive ? 'AB' : 'ab', shiftActive, onShiftToggle),
          _buildModifierKey(capsLock ? 'AA' : 'Aa', capsLock, onCapsLockToggle),
          _buildArrowKey('Up', '\x1b[A', Icons.arrow_upward),
          _buildArrowKey('Down', '\x1b[B', Icons.arrow_downward),
          _buildArrowKey('Left', '\x1b[D', Icons.arrow_back),
          _buildArrowKey('Right', '\x1b[C', Icons.arrow_forward),
        ],
      ),
    );
  }
}
