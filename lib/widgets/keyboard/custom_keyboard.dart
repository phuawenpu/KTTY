import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/keyboard_state.dart';
import 'control_cluster.dart';
import 'keyboard_layer.dart';
import 'key_definitions.dart';

class CustomKeyboard extends StatefulWidget {
  final ValueChanged<String> onKeyPressed;
  final bool disabled;

  const CustomKeyboard({
    super.key,
    required this.onKeyPressed,
    this.disabled = false,
  });

  @override
  State<CustomKeyboard> createState() => _CustomKeyboardState();
}

class _CustomKeyboardState extends State<CustomKeyboard> {
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onKeyPressed(String value) {
    if (widget.disabled) return;
    final ks = context.read<KeyboardState>();

    widget.onKeyPressed(value);

    // Clear shift after one keypress (not caps lock)
    if (ks.shiftActive) {
      ks.toggleShift();
    }
    // Clear ctrl after one keypress
    if (ks.ctrlActive) {
      ks.toggleCtrl();
    }
  }

  void _switchLayer(int layer) {
    final ks = context.read<KeyboardState>();
    ks.setLayer(layer);
    _pageController.animateToPage(
      layer,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ks = context.watch<KeyboardState>();

    return IgnorePointer(
      ignoring: widget.disabled,
      child: Opacity(
        opacity: widget.disabled ? 0.4 : 1.0,
        child: Container(
          color: const Color(0xFF1A1A2E),
          child: Column(
            children: [
              // Control cluster
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
                onKeyPressed: _onKeyPressed,
              ),
              // Layer indicator + swipe strip
              _buildLayerIndicator(ks.activeLayer),
              // Keyboard layers (swipeable)
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (index) {
                    context.read<KeyboardState>().setLayer(index);
                  },
                  itemCount: kAllLayers.length,
                  itemBuilder: (context, index) {
                    return KeyboardLayer(
                      rows: kAllLayers[index],
                      isUpperCase: ks.isUpperCase,
                      ctrlActive: ks.ctrlActive,
                      onKeyPressed: _onKeyPressed,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLayerIndicator(int activeLayer) {
    return SizedBox(
      height: 24,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(kLayerNames.length, (index) {
          final isActive = index == activeLayer;
          return GestureDetector(
            onTap: () => _switchLayer(index),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFF0F3460) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                kLayerNames[index],
                style: TextStyle(
                  color: isActive ? Colors.blueAccent : Colors.white38,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
