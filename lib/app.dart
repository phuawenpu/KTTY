import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/connection_state.dart';
import 'services/websocket/websocket_service.dart';
import 'services/terminal/terminal_service.dart';
import 'state/session_state.dart';
import 'state/viewport_state.dart';
import 'state/keyboard_state.dart';
import 'screens/dashboard_screen.dart';
import 'screens/terminal_screen.dart';

class KttyApp extends StatefulWidget {
  const KttyApp({super.key});

  @override
  State<KttyApp> createState() => _KttyAppState();
}

class _KttyAppState extends State<KttyApp> with WidgetsBindingObserver {
  late final WebSocketService _wsService;
  late final TerminalService _terminalService;
  late final SessionState _sessionState;
  Timer? _backgroundTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wsService = WebSocketService();
    _terminalService = TerminalService(_wsService);
    _sessionState = SessionState();

    // Wire up reconnect handler
    _wsService.onReconnected = _handleReconnected;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundTimer?.cancel();
    _terminalService.dispose();
    _wsService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('[KTTY] App lifecycle: $state');

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // Start background timer — close WS after 90s to save resources
        _backgroundTimer?.cancel();
        _backgroundTimer = Timer(const Duration(seconds: 90), () {
          print('[KTTY] Background timeout — closing WS (credentials preserved)');
          _wsService.backgroundClose();
        });
        break;

      case AppLifecycleState.resumed:
        // Cancel background timer if we returned quickly
        _backgroundTimer?.cancel();
        _backgroundTimer = null;

        // Auto-reconnect if we were connected and WS died
        if (_sessionState.status == ConnectionStatus.connected ||
            _sessionState.status == ConnectionStatus.syncing) {
          if (!_wsService.isConnected) {
            print('[KTTY] Resumed with dead WS — attempting reconnect');
            _sessionState.setStatus(ConnectionStatus.syncing);
            _wsService.attemptReconnect();
          } else {
            print('[KTTY] Resumed — WS still alive');
          }
        }
        break;

      default:
        break;
    }
  }

  void _handleReconnected() {
    print('[KTTY] Reconnected — requesting sync');
    _terminalService.reattachAfterReconnect();
    _sessionState.setStatus(ConnectionStatus.connected);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _sessionState),
        ChangeNotifierProvider(create: (_) => ViewportState()),
        ChangeNotifierProvider(create: (_) => KeyboardState()),
      ],
      child: MaterialApp(
        title: 'KTTY',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF1A1A2E),
        ),
        initialRoute: '/dashboard',
        routes: {
          '/dashboard': (_) => DashboardScreen(
                wsService: _wsService,
                terminalService: _terminalService,
              ),
          '/terminal': (_) => TerminalScreen(
                terminalService: _terminalService,
                wsService: _wsService,
              ),
        },
      ),
    );
  }
}
