import 'dart:io';
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

  // Track which field is focused
  final _urlFocusNode = FocusNode();
  final _pinFocusNode = FocusNode();
  TextEditingController? _activeController;

  bool _relayReachable = false;

  @override
  void initState() {
    super.initState();
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    _urlFocusNode.addListener(_onUrlFocus);
    _pinFocusNode.addListener(_onPinFocus);

    // Default focus to URL field
    _activeController = _urlController;

    // Auto-ping relay on startup
    _pingRelay();
  }

  Future<void> _pingRelay() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    print('[KTTY] Ping: attempting connection to $url');

    try {
      final httpUrl = url
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://')
          .replaceFirst('/ws', '/');

      final uri = Uri.parse(httpUrl);
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      client.badCertificateCallback = (cert, host, port) => true;
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 5));
      await response.drain();

      print('[KTTY] Ping: HTTP ${response.statusCode} from $httpUrl');
      setState(() => _relayReachable = true);
      if (mounted) context.read<SessionState>().setRelayReachable(true);
      client.close();
    } catch (e) {
      print('[KTTY] Ping failed: $e');
      setState(() => _relayReachable = false);
      if (mounted) context.read<SessionState>().setRelayReachable(false);
    }
  }

  void _onUrlFocus() {
    if (_urlFocusNode.hasFocus) {
      setState(() => _activeController = _urlController);
      context.read<KeyboardState>().setLayer(0); // ABC for URL
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }
  }

  void _onPinFocus() {
    if (_pinFocusNode.hasFocus) {
      setState(() => _activeController = _pinController);
      context.read<KeyboardState>().setLayer(1); // 123 for PIN
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }
  }

  void _onKeyPressed(String value) {
    final controller = _activeController;
    if (controller == null) return;

    if (value == '\x7F' || value == '\x1b[3~') {
      // Backspace or Delete
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
      // Enter — move to next field or connect
      if (_activeController == _urlController) {
        _pinFocusNode.requestFocus();
      } else {
        _connect();
      }
    } else if (value == '\t') {
      // Tab — switch fields
      if (_activeController == _urlController) {
        _pinFocusNode.requestFocus();
      } else {
        _urlFocusNode.requestFocus();
      }
    } else if (value.codeUnitAt(0) >= 32) {
      // Printable character — insert at cursor
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

  Future<void> _connect() async {
    final session = context.read<SessionState>();
    final url = _urlController.text.trim();
    final pin = _pinController.text.trim();

    if (url.isEmpty || pin.isEmpty) return;

    setState(() => _connecting = true);
    session.setUrl(url);
    session.setPin(pin);
    session.setStatus(ConnectionStatus.connectingRelay);

    try {
      print('[KTTY] Connect tapped. URL=$url PIN length=${pin.length}');

      widget.wsService.onConnectionChanged = (connected) {
        print('[KTTY] Connection state changed: $connected');
        if (connected) {
          session.setStatus(ConnectionStatus.connected);
        } else {
          session.setStatus(ConnectionStatus.syncing);
        }
      };

      print('[KTTY] Connecting to relay...');
      await widget.wsService.connect(url);
      session.setStatus(ConnectionStatus.relayConnected);
      print('[KTTY] Relay connected. Starting handshake...');

      session.setStatus(ConnectionStatus.waitingForAgent);
      await widget.wsService.performHandshake(pin);
      print('[KTTY] Agent found.');

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

      // Determine user-friendly error message
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
        // 5 second cooldown after failure to prevent rapid retries
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
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/ktty_logo.png', height: 28),
            const SizedBox(width: 8),
            const Text('KTTY'),
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
          // Form area: 65%
          Expanded(
            flex: kPortraitTerminalFlex,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: const Color(0xFF0F1923),
                    padding: const EdgeInsets.all(16),
                    child: Image.asset(
                      'assets/ktty_logo.png',
                      height: 240,
                    ),
                  ),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pinController,
                    focusNode: _pinFocusNode,
                    readOnly: true,
                    showCursor: true,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      labelStyle: const TextStyle(color: Colors.white54),
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
                  const SizedBox(height: 24),
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
                            style:
                                TextStyle(fontSize: 16, color: Colors.white),
                          ),
                  ),
                ],
              ),
            ),
          ),
          // Keyboard: 35%
          Expanded(
            flex: kPortraitKeyboardFlex,
            child: CustomKeyboard(
              onKeyPressed: _onKeyPressed,
            ),
          ),
        ],
      ),
    );
  }
}
