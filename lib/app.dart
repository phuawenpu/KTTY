import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

class _KttyAppState extends State<KttyApp> {
  late final WebSocketService _wsService;
  late final TerminalService _terminalService;

  @override
  void initState() {
    super.initState();
    _wsService = WebSocketService();
    _terminalService = TerminalService(_wsService);
  }

  @override
  void dispose() {
    _terminalService.dispose();
    _wsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SessionState()),
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
              ),
        },
      ),
    );
  }
}
