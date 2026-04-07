import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/viewport_mode.dart';
import '../../state/keyboard_state.dart';
import '../clipboard/clipboard_buttons.dart';
import 'control_cluster.dart';
import 'keyboard_layer.dart';
import 'key_definitions.dart';

class CustomKeyboard extends StatelessWidget {
  final ValueChanged<String> onKeyPressed;
  final bool disabled;
  final ViewportMode viewportMode;
  final String Function()? onGetSelectedText;
  final ValueChanged<String>? onPaste;

  const CustomKeyboard({
    super.key,
    required this.onKeyPressed,
    this.disabled = false,
    this.viewportMode = ViewportMode.portrait,
    this.onGetSelectedText,
    this.onPaste,
  });

  void _onKeyPressed(BuildContext context, String value) {
    if (disabled) return;
    final ks = context.read<KeyboardState>();

    onKeyPressed(value);

    if (ks.shiftActive) {
      ks.toggleShift();
    }
    if (ks.ctrlActive) {
      ks.toggleCtrl();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ks = context.watch<KeyboardState>();

    return IgnorePointer(
      ignoring: disabled,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Container(
          color: const Color(0xFF1A1A2E),
          child: Column(
            children: [
              ControlCluster(
                ctrlActive: ks.ctrlActive,
                shiftActive: ks.shiftActive,
                capsLock: ks.capsLock,
                onCtrlToggle: () =>
                    context.read<KeyboardState>().toggleCtrl(),
                onShiftToggle: () =>
                    context.read<KeyboardState>().toggleShift(),
                onCapsLockToggle: () =>
                    context.read<KeyboardState>().toggleCapsLock(),
                onKeyPressed: (v) => _onKeyPressed(context, v),
              ),
              // Toolbar: layer switch + Bksp + Del + clipboard icons
              _buildToolbar(context, ks.activeLayer),
              // Key grid
              Expanded(
                child: IndexedStack(
                  index: ks.activeLayer,
                  children: List.generate(kAllLayers.length, (index) {
                    return KeyboardLayer(
                      rows: kAllLayers[index],
                      isUpperCase: ks.isUpperCase,
                      ctrlActive: ks.ctrlActive,
                      onKeyPressed: (v) => _onKeyPressed(context, v),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, int activeLayer) {
    return SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            // Layer indicators
            ...List.generate(kLayerNames.length, (index) {
              final isActive = index == activeLayer;
              return GestureDetector(
                onTap: () =>
                    context.read<KeyboardState>().setLayer(index),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFF0F3460)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    kLayerNames[index],
                    style: TextStyle(
                      color:
                          isActive ? Colors.blueAccent : Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            }),
            const Spacer(),
            // Backspace
            _buildToolbarButton(
              context, Icons.backspace_outlined, 'Backspace',
              () => _onKeyPressed(context, '\x7F'),
            ),
            // Delete
            _buildToolbarButton(
              context, Icons.delete_outline, 'Delete',
              () => _onKeyPressed(context, '\x1b[3~'),
            ),
            // Divider
            Container(
              width: 1, height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: Colors.white24,
            ),
            // Clipboard buttons
            if (onGetSelectedText != null)
              ClipboardButtons(
                mode: viewportMode,
                onGetSelectedText: onGetSelectedText!,
                onPaste: onPaste,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarButton(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Icon(icon, color: Colors.white70, size: 20),
          ),
        ),
      ),
    );
  }
}
