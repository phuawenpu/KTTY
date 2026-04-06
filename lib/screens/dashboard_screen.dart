import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/connection_state.dart';
import '../services/websocket/websocket_service.dart';
import '../services/terminal/terminal_service.dart';
import '../state/session_state.dart';
import '../widgets/terminal/connection_indicator.dart';

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
  final _urlController = TextEditingController(text: 'ws://localhost:8080');
  final _pinController = TextEditingController();
  bool _connecting = false;

  Future<void> _connect() async {
    final session = context.read<SessionState>();
    final url = _urlController.text.trim();
    final pin = _pinController.text.trim();

    if (url.isEmpty || pin.isEmpty) return;

    setState(() => _connecting = true);
    session.setUrl(url);
    session.setPin(pin);
    session.setStatus(ConnectionStatus.syncing);

    try {
      // Wire connection state changes to session
      widget.wsService.onConnectionChanged = (connected) {
        if (connected) {
          session.setStatus(ConnectionStatus.connected);
        } else {
          session.setStatus(ConnectionStatus.syncing);
        }
      };

      await widget.wsService.connect(url);

      // Perform ML-KEM handshake (join + key exchange)
      await widget.wsService.performHandshake(pin);

      widget.terminalService.attach();
      session.setStatus(ConnectionStatus.connected);

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/terminal');
      }
    } catch (e) {
      session.setStatus(ConnectionStatus.disconnected);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('KTTY'),
        backgroundColor: const Color(0xFF16213E),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: ConnectionIndicator(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Session Dashboard',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'WebSocket URL',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.blueAccent),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pinController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'PIN',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
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
                      style: TextStyle(fontSize: 16, color: Colors.white),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
