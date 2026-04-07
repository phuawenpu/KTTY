import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../config/constants.dart';
import '../models/connection_state.dart';
import '../models/viewport_mode.dart';
import '../state/session_state.dart';
import '../state/viewport_state.dart';
import '../services/terminal/terminal_service.dart';
import '../services/websocket/websocket_service.dart';
import '../widgets/terminal/terminal_container.dart';
import '../widgets/terminal/connection_indicator.dart';
import '../widgets/keyboard/custom_keyboard.dart';

class TerminalScreen extends StatefulWidget {
  final TerminalService terminalService;
  final WebSocketService wsService;

  const TerminalScreen({
    super.key,
    required this.terminalService,
    required this.wsService,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  bool _resizeSent = false;

  @override
  void initState() {
    super.initState();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    // Send terminal size to agent once xterm calculates it
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendInitialResize();
    });
  }

  void _sendInitialResize() {
    // xterm auto-calculates cols/rows from font size and container
    // Wait a moment for the layout to settle, then send resize
    Future.delayed(const Duration(milliseconds: 500), () {
      final term = widget.terminalService.terminal;
      final cols = term.viewWidth;
      final rows = term.viewHeight;
      if (cols > 0 && rows > 0 && !_resizeSent) {
        _resizeSent = true;
        print('[KTTY] Sending initial resize: ${cols}x$rows');
        widget.terminalService.sendResize(cols, rows);
      }
    });
  }

  void _onKeyPressed(String value) {
    widget.terminalService.terminal.textInput(value);
  }

  void _disconnect() {
    // Only close the connection — do NOT kill the remote shell
    widget.terminalService.detach();
    widget.wsService.disconnect();
    context.read<SessionState>().setStatus(ConnectionStatus.disconnected);

    // Navigate back to dashboard
    Navigator.pushReplacementNamed(context, '/dashboard');
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
    final keyboardDisabled = status != ConnectionStatus.connected && status != ConnectionStatus.syncing;

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/ktty_logo.png', height: 22),
              const SizedBox(width: 6),
              const Text('KTTY'),
            ],
          ),
          backgroundColor: const Color(0xFF16213E),
          toolbarHeight: 32,
          titleTextStyle: const TextStyle(fontSize: 17),
          actions: [
            // Disconnect button
            IconButton(
              icon: const Icon(Icons.exit_to_app, size: 18),
              onPressed: _disconnect,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Disconnect',
            ),
            const SizedBox(width: 8),
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
