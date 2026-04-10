import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/viewport_mode.dart';
import '../../state/keyboard_state.dart';
import '../clipboard/clipboard_buttons.dart';
import 'control_cluster.dart';
import 'keyboard_layer.dart';
import 'key_definitions.dart';

class CustomKeyboard extends StatefulWidget {
  final ValueChanged<String> onKeyPressed;
  final bool disabled;
  final ViewportMode viewportMode;
  final String Function()? onGetSelectedText;
  final ValueChanged<String>? onPaste;
  final bool pinEntryMode;
  final VoidCallback? onMicPressed;
  final bool isListening;
  final VoidCallback? onHideKeyboard;

  const CustomKeyboard({
    super.key,
    required this.onKeyPressed,
    this.disabled = false,
    this.viewportMode = ViewportMode.portrait,
    this.onGetSelectedText,
    this.onPaste,
    this.pinEntryMode = false,
    this.onMicPressed,
    this.isListening = false,
    this.onHideKeyboard,
  });

  @override
  State<CustomKeyboard> createState() => _CustomKeyboardState();
}

class _CustomKeyboardState extends State<CustomKeyboard>
    with SingleTickerProviderStateMixin {
  // Which drawer is open: null = none, 0 = numeric (left), 1 = symbol (right)
  int? _openDrawer;

  void _onKeyPressed(BuildContext context, String value) {
    if (widget.disabled) return;
    final ks = context.read<KeyboardState>();

    // Handle the special shift key from the bottom row
    if (value == '\x00SHIFT') {
      ks.toggleShift();
      return;
    }

    widget.onKeyPressed(value);

    if (ks.shiftActive) {
      ks.toggleShift();
    }
    if (ks.ctrlActive) {
      ks.toggleCtrl();
    }
  }

  void _toggleDrawer(int drawer) {
    setState(() {
      _openDrawer = _openDrawer == drawer ? null : drawer;
    });
  }

  void _closeDrawer() {
    if (_openDrawer != null) {
      setState(() => _openDrawer = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ks = context.watch<KeyboardState>();

    // PIN entry mode — show simplified numeric pad
    if (widget.pinEntryMode) {
      return _buildPinPad(context);
    }

    return IgnorePointer(
      ignoring: widget.disabled,
      child: Opacity(
        opacity: widget.disabled ? 0.4 : 1.0,
        child: Container(
          color: const Color(0xFF1A1A2E),
          child: Column(
            children: [
              ControlCluster(
                ctrlActive: ks.ctrlActive,
                capsLock: ks.capsLock,
                onCtrlToggle: () =>
                    context.read<KeyboardState>().toggleCtrl(),
                onCapsLockToggle: () =>
                    context.read<KeyboardState>().toggleCapsLock(),
                onKeyPressed: (v) => _onKeyPressed(context, v),
                onHideKeyboard: widget.onHideKeyboard,
              ),
              // Toolbar: ABC label + Bksp + Del + clipboard icons
              _buildToolbar(context),
              // Key grid with edge handles and drawer overlays
              Expanded(
                child: Stack(
                  children: [
                    // Main ABC layer — inset slightly so edge handles don't overlap keys
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: KeyboardLayer(
                      rows: kLayer0,
                      isUpperCase: ks.isUpperCase,
                      ctrlActive: ks.ctrlActive,
                      onKeyPressed: (v) => _onKeyPressed(context, v),
                      onSpaceLongPress: widget.onMicPressed,
                      spaceLongPressActive: widget.isListening,
                    )),
                    // Left edge handle (123 numeric)
                    _buildEdgeHandle(
                      fromLeft: true,
                      label: '1\n2\n3',
                      drawer: 0,
                    ),
                    // Right edge handle (SYM)
                    _buildEdgeHandle(
                      fromLeft: false,
                      label: 'S\nY\nM',
                      drawer: 1,
                    ),
                    // Numeric drawer (slides from left)
                    _buildDrawer(
                      context,
                      drawer: 0,
                      layer: kLayer1,
                      fromLeft: true,
                      ks: ks,
                    ),
                    // Symbol drawer (slides from right)
                    _buildDrawer(
                      context,
                      drawer: 1,
                      layer: kLayer2,
                      fromLeft: false,
                      ks: ks,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinPad(BuildContext context) {
    const pinKeys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['\u232B', '0', '\u23CE'],
    ];
    const pinValues = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['\x7F', '0', '\r'],
    ];

    return IgnorePointer(
      ignoring: widget.disabled,
      child: Opacity(
        opacity: widget.disabled ? 0.4 : 1.0,
        child: Container(
          color: const Color(0xFF1A1A2E),
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(4, (row) {
              return Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(3, (col) {
                    final label = pinKeys[row][col];
                    final value = pinValues[row][col];
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2.25),
                        child: Material(
                          color: const Color(0xFF0F3460),
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            onTap: () => _onKeyPressed(context, value),
                            borderRadius: BorderRadius.circular(8),
                            child: Center(
                              child: Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildEdgeHandle({
    required bool fromLeft,
    required String label,
    required int drawer,
  }) {
    // Only show handle when this drawer is closed
    if (_openDrawer == drawer) return const SizedBox.shrink();

    return Positioned(
      top: 0,
      bottom: 0,
      left: fromLeft ? 0 : null,
      right: fromLeft ? null : 0,
      child: GestureDetector(
        onTap: () => _toggleDrawer(drawer),
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          // Swipe right on left edge → open 123
          if (fromLeft && v > 150) _toggleDrawer(drawer);
          // Swipe left on right edge → open SYM
          if (!fromLeft && v < -150) _toggleDrawer(drawer);
        },
        child: Container(
          width: 11,
          decoration: BoxDecoration(
            color: const Color(0xFF0F3460).withValues(alpha: 0.6),
            borderRadius: fromLeft
                ? const BorderRadius.only(
                    topRight: Radius.circular(6),
                    bottomRight: Radius.circular(6),
                  )
                : const BorderRadius.only(
                    topLeft: Radius.circular(6),
                    bottomLeft: Radius.circular(6),
                  ),
          ),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 6.5,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer(
    BuildContext context, {
    required int drawer,
    required List<List<KeyDef>> layer,
    required bool fromLeft,
    required KeyboardState ks,
  }) {
    final isOpen = _openDrawer == drawer;
    final screenWidth = MediaQuery.of(context).size.width;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      top: 0,
      bottom: 0,
      left: fromLeft ? (isOpen ? 0 : -screenWidth) : null,
      right: fromLeft ? null : (isOpen ? 0 : -screenWidth),
      width: screenWidth,
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          // Swipe left to dismiss left drawer
          if (fromLeft && v < -200) _closeDrawer();
          // Swipe right to dismiss right drawer
          if (!fromLeft && v > 200) _closeDrawer();
        },
        child: Container(
          color: const Color(0xFF1A1A2E),
          child: KeyboardLayer(
            rows: layer,
            isUpperCase: ks.isUpperCase,
            ctrlActive: ks.ctrlActive,
            onKeyPressed: (v) => _onKeyPressed(context, v),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            // ABC label (always active since it's the main layer)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _openDrawer == null
                    ? const Color(0xFF0F3460)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: GestureDetector(
                onTap: _closeDrawer,
                child: Text(
                  'ABC',
                  style: TextStyle(
                    color: _openDrawer == null
                        ? Colors.blueAccent
                        : Colors.white38,
                    fontSize: 13.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            // 123 drawer toggle
            GestureDetector(
              onTap: () => _toggleDrawer(0),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _openDrawer == 0
                      ? const Color(0xFF0F3460)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '123',
                  style: TextStyle(
                    color: _openDrawer == 0
                        ? Colors.blueAccent
                        : Colors.white38,
                    fontSize: 13.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            // SYM drawer toggle
            GestureDetector(
              onTap: () => _toggleDrawer(1),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _openDrawer == 1
                      ? const Color(0xFF0F3460)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'SYM',
                  style: TextStyle(
                    color: _openDrawer == 1
                        ? Colors.blueAccent
                        : Colors.white38,
                    fontSize: 13.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            // (Keyboard-hide button moved up to the control cluster row.)
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
            if (widget.onGetSelectedText != null)
              ClipboardButtons(
                mode: widget.viewportMode,
                onGetSelectedText: widget.onGetSelectedText!,
                onPaste: widget.onPaste,
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
