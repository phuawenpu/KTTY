import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../config/constants.dart';
import '../models/connection_state.dart';
import '../models/viewport_mode.dart';
import '../state/session_state.dart';
import '../state/viewport_state.dart';
import '../services/terminal/terminal_service.dart';
import '../widgets/terminal/terminal_container.dart';
import '../widgets/terminal/connection_indicator.dart';
import '../widgets/keyboard/custom_keyboard.dart';

class TerminalScreen extends StatefulWidget {
  final TerminalService terminalService;

  const TerminalScreen({super.key, required this.terminalService});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  @override
  void initState() {
    super.initState();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  void _onKeyPressed(String value) {
    widget.terminalService.terminal.textInput(value);
  }

  void _toggleViewport() {
    final vs = context.read<ViewportState>();

    if (vs.mode == ViewportMode.portrait) {
      vs.setResizing(true);
      vs.setMode(ViewportMode.landscape);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      vs.setResizing(true);
      vs.setMode(ViewportMode.portrait);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        vs.setResizing(false);
      }
    });
  }

  String _getSelectedText() {
    return widget.terminalService.getSelectedText();
  }

  @override
  Widget build(BuildContext context) {
    final status = context.watch<SessionState>().status;
    final vs = context.watch<ViewportState>();
    final isPortrait = vs.mode == ViewportMode.portrait;
    final keyboardDisabled = status != ConnectionStatus.connected;

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('KTTY Terminal'),
          backgroundColor: const Color(0xFF16213E),
          toolbarHeight: 36,
          titleTextStyle: const TextStyle(fontSize: 14),
          actions: [
            IconButton(
              icon: Icon(
                isPortrait
                    ? Icons.screen_rotation
                    : Icons.stay_current_portrait,
                size: 18,
              ),
              onPressed: _toggleViewport,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: ConnectionIndicator(),
            ),
          ],
        ),
        body: isPortrait
            ? Column(
                children: [
                  Expanded(
                    flex: kPortraitTerminalFlex,
                    child: TerminalContainer(
                      terminal: widget.terminalService.terminal,
                      controller: widget.terminalService.controller,
                    ),
                  ),
                  Expanded(
                    flex: kPortraitKeyboardFlex,
                    child: CustomKeyboard(
                      onKeyPressed: _onKeyPressed,
                      disabled: keyboardDisabled,
                      viewportMode: vs.mode,
                      onGetSelectedText: _getSelectedText,
                      onPaste: (text) {
                        widget.terminalService.terminal.paste(text);
                      },
                    ),
                  ),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(4),
                child: TerminalContainer(
                  terminal: widget.terminalService.terminal,
                  controller: widget.terminalService.controller,
                ),
              ),
      ),
    );
  }
}
