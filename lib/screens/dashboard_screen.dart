import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../config/constants.dart';
import '../models/connection_state.dart';
import '../services/websocket/websocket_service.dart';
import '../services/terminal/terminal_service.dart';
import '../state/session_state.dart';
import '../state/keyboard_state.dart';
import '../widgets/terminal/connection_indicator.dart';
import '../widgets/keyboard/custom_keyboard.dart';
import 'ping_native.dart' if (dart.library.js_interop) 'ping_web.dart'
    as ping;

class DashboardScreen extends StatefulWidget {
  final WebSocketService wsService;
  final TerminalService terminalService;

  const DashboardScreen({
    super.key,
    required this.wsService,
    required this.terminalService,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _urlController = TextEditingController(text: 'wss://ktty-relay.fly.dev/ws');
  final _pinController = TextEditingController();
  bool _connecting = false;
  bool _pinVisible = false;

  final _urlFocusNode = FocusNode();
  final _pinFocusNode = FocusNode();
  TextEditingController? _activeController;

  bool _relayReachable = false;

  // Rate limiting for PIN attempts (PWA only)
  int _pinAttempts = 0;
  DateTime? _lockoutUntil;
  static const _maxAttempts = 5;
  static const _lockoutDuration = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      _urlFocusNode.addListener(_onUrlFocus);
      _activeController = _urlController;
      _pingRelay();
    } else {
      _activeController = _pinController;
    }
    _pinFocusNode.addListener(_onPinFocus);
  }

  Future<void> _pingRelay() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    try {
      final reachable = await ping.pingRelay(url);
      setState(() => _relayReachable = reachable);
      if (mounted) context.read<SessionState>().setRelayReachable(reachable);
    } catch (e) {
      print('[KTTY] Ping failed: $e');
      setState(() => _relayReachable = false);
      if (mounted) context.read<SessionState>().setRelayReachable(false);
    }
  }

  void _onUrlFocus() {
    if (_urlFocusNode.hasFocus) {
      setState(() => _activeController = _urlController);
      context.read<KeyboardState>().setLayer(0);
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }
  }

  void _onPinFocus() {
    if (_pinFocusNode.hasFocus) {
      setState(() => _activeController = _pinController);
      context.read<KeyboardState>().setLayer(1);
      if (!kIsWeb) SystemChannels.textInput.invokeMethod('TextInput.hide');
    }
  }

  void _onKeyPressed(String value) {
    final controller = _activeController;
    if (controller == null) return;

    if (value == '\x7F' || value == '\x1b[3~') {
      final text = controller.text;
      if (text.isNotEmpty) {
        final sel = controller.selection;
        if (sel.isValid && sel.start > 0) {
          controller.text =
              text.substring(0, sel.start - 1) + text.substring(sel.start);
          controller.selection =
              TextSelection.collapsed(offset: sel.start - 1);
        } else {
          controller.text = text.substring(0, text.length - 1);
          controller.selection =
              TextSelection.collapsed(offset: controller.text.length);
        }
      }
    } else if (value == '\r' || value == '\n') {
      if (!kIsWeb && _activeController == _urlController) {
        _pinFocusNode.requestFocus();
      } else {
        _connect();
      }
    } else if (value == '\t') {
      if (!kIsWeb) {
        if (_activeController == _urlController) {
          _pinFocusNode.requestFocus();
        } else {
          _urlFocusNode.requestFocus();
        }
      }
    } else if (value.codeUnitAt(0) >= 32) {
      final text = controller.text;
      final sel = controller.selection;
      if (sel.isValid) {
        controller.text = text.substring(0, sel.start) +
            value +
            text.substring(sel.end);
        controller.selection =
            TextSelection.collapsed(offset: sel.start + value.length);
      } else {
        controller.text += value;
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);
      }
    }
  }

  bool get _isLockedOut {
    if (_lockoutUntil == null) return false;
    if (DateTime.now().isAfter(_lockoutUntil!)) {
      _lockoutUntil = null;
      _pinAttempts = 0;
      return false;
    }
    return true;
  }

  int get _lockoutSecondsRemaining {
    if (_lockoutUntil == null) return 0;
    return _lockoutUntil!.difference(DateTime.now()).inSeconds.clamp(0, 999);
  }

  Future<void> _connect() async {
    final session = context.read<SessionState>();
    final pin = _pinController.text.trim().replaceAll(RegExp(r'[^0-9]'), '');
    if (pin.isEmpty) return;

    // Rate limiting (PWA)
    if (kIsWeb && _isLockedOut) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Too many attempts. Try again in ${_lockoutSecondsRemaining}s.'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    String url;
    if (kIsWeb) {
      // Use relay URL embedded at build time (not shown to user)
      if (kRelayUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No relay URL configured. Rebuild with --dart-define=RELAY_URL=<url>'),
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }
      url = kRelayUrl;
    } else {
      url = _urlController.text.trim();
      if (url.isEmpty) return;
    }

    setState(() => _connecting = true);
    session.setUrl(url);
    session.setPin(pin);
    session.setStatus(ConnectionStatus.connectingRelay);

    try {
      print('[KTTY] Connecting...');

      widget.wsService.onConnectionChanged = (connected) {
        if (connected) {
          session.setStatus(ConnectionStatus.connected);
        } else {
          session.setStatus(ConnectionStatus.syncing);
        }
      };

      await widget.wsService.connect(url);
      session.setStatus(ConnectionStatus.relayConnected);

      session.setStatus(ConnectionStatus.waitingForAgent);
      await widget.wsService.performHandshake(pin);

      widget.terminalService.terminal.write('\x1b[2J\x1b[H');
      widget.terminalService.attach();
      session.setStatus(ConnectionStatus.connected);

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/terminal');
      }
    } catch (e, st) {
      print('[KTTY] Connection failed: $e');
      print('[KTTY] Stack: ${st.toString().split('\n').take(5).join('\n')}');
      widget.wsService.disconnect();
      session.setStatus(ConnectionStatus.disconnected);

      String errorMsg;
      if (e.toString().contains('No agent found')) {
        errorMsg = 'No agent found. Wrong PIN or agent not running.';
      } else if (e.toString().contains('host lookup')) {
        errorMsg = 'Cannot reach relay server.';
      } else if (e.toString().contains('TimeoutException')) {
        errorMsg = 'Connection timed out. Agent may not be running.';
      } else {
        errorMsg = 'Connection failed: $e';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
        if (session.status == ConnectionStatus.disconnected) {
          setState(() => _connecting = true);
          await Future.delayed(const Duration(seconds: 5));
          if (mounted) setState(() => _connecting = false);
        }
      }
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _pinController.dispose();
    _urlFocusNode.dispose();
    _pinFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
      backgroundColor: const Color(0xFF101721),
      appBar: AppBar(
        toolbarHeight: 40,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/ktty_logo.png', height: 24),
            const SizedBox(width: 6),
            const Text('KTTY'),
            const SizedBox(width: 8),
            Text(
              'v$kAppVersion ${kAppBuildTime == 'dev' ? '' : kAppBuildTime}',
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF16213E),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: ConnectionIndicator(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: kPortraitTerminalFlex,
            child: Stack(
              children: [
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: const Color(0xFF101721),
                    child: Image.asset('assets/ktty_logo.png', height: 240),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Mobile only: plaintext URL field
                        if (!kIsWeb) ...[
                          TextField(
                            controller: _urlController,
                            focusNode: _urlFocusNode,
                            readOnly: true,
                            showCursor: true,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'WebSocket URL',
                              labelStyle: const TextStyle(color: Colors.white54),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: _activeController == _urlController
                                      ? Colors.blueAccent
                                      : Colors.white24,
                                ),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.blueAccent),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        // PIN field (both platforms)
                        TextField(
                          controller: _pinController,
                          focusNode: _pinFocusNode,
                          readOnly: !kIsWeb,
                          showCursor: true,
                          obscureText: !_pinVisible,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'PIN',
                            labelStyle: const TextStyle(color: Colors.white54),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _pinVisible ? Icons.visibility_off : Icons.visibility,
                                color: Colors.white38,
                                size: 20,
                              ),
                              onPressed: () => setState(() => _pinVisible = !_pinVisible),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                color: _activeController == _pinController
                                    ? Colors.blueAccent
                                    : Colors.white24,
                              ),
                            ),
                            focusedBorder: const OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.blueAccent),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _connecting ? null : _connect,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F3460),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: _connecting
                              ? const CircularProgressIndicator(color: Colors.white)
                              : const Text(
                                  'Connect',
                                  style: TextStyle(fontSize: 19, color: Colors.white),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Keyboard
          Expanded(
            flex: kPortraitKeyboardFlex,
            child: CustomKeyboard(
              onKeyPressed: _onKeyPressed,
              pinEntryMode: _activeController == _pinController,
            ),
          ),
        ],
      ),
    ),
    );
  }
}
