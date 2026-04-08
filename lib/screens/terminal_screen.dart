import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  final _terminalKey = GlobalKey<TerminalContainerState>();
  double _displayFontSize = 14.0;

  @override
  void initState() {
    super.initState();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final t = widget.terminalService.terminal;
      if (t.viewWidth > 0 && t.viewHeight > 0) {
        print('[KTTY] Post-frame resize: ${t.viewWidth}x${t.viewHeight}');
        widget.terminalService.sendResize(t.viewWidth, t.viewHeight);
      }
    });
  }

  void _onKeyPressed(String value) {
    widget.terminalService.terminal.textInput(value);
  }

  void _disconnect() {
    widget.terminalService.detach();
    widget.wsService.disconnect();
    context.read<SessionState>().setStatus(ConnectionStatus.disconnected);
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
    final keyboardDisabled = status != ConnectionStatus.connected &&
        status != ConnectionStatus.syncing;

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
              const SizedBox(width: 8),
              // Connection status immediately after KTTY
              const ConnectionIndicator(),
            ],
          ),
          backgroundColor: const Color(0xFF16213E),
          toolbarHeight: 32,
          titleTextStyle: const TextStyle(fontSize: 17),
          actions: [
            // Font size controls
            _buildHeaderButton(Icons.remove, () {
              _terminalKey.currentState?.zoomOut();
            }),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                '${_displayFontSize.round()}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                ),
              ),
            ),
            _buildHeaderButton(Icons.add, () {
              _terminalKey.currentState?.zoomIn();
            }),
            const SizedBox(width: 6),
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
            const SizedBox(width: 12),
          ],
        ),
        body: isPortrait
            ? Column(
                children: [
                  Expanded(
                    flex: kPortraitTerminalFlex,
                    child: TerminalContainer(
                      key: _terminalKey,
                      terminal: widget.terminalService.terminal,
                      controller: widget.terminalService.controller,
                      onFontSizeChanged: (size) {
                        setState(() => _displayFontSize = size);
                      },
                      onWordTapped: (word) {
                        widget.terminalService.terminal.textInput(word);
                      },
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
                  key: _terminalKey,
                  terminal: widget.terminalService.terminal,
                  controller: widget.terminalService.controller,
                  onFontSizeChanged: (size) {
                    setState(() => _displayFontSize = size);
                  },
                  onWordTapped: (word) {
                    widget.terminalService.terminal.textInput(word);
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildHeaderButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: const Color(0xFF2A2A4A).withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, color: Colors.white54, size: 14),
        ),
      ),
    );
  }
}
