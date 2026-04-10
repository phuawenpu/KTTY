import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/connection_state.dart';
import '../../state/session_state.dart';

/// Map (status, relayReachable) → an indicator colour. Used by both
/// the dot ([ConnectionIndicator]) and the KTTY title ([KttyTitle]) so
/// they always agree on what colour they're showing.
Color statusColor(ConnectionStatus status, bool relayReachable) {
  switch (status) {
    case ConnectionStatus.disconnected:
      return relayReachable ? const Color(0xFF4488FF) : Colors.red;
    case ConnectionStatus.connectingRelay:
      return Colors.orange;
    case ConnectionStatus.relayConnected:
      return Colors.orange;
    case ConnectionStatus.handshaking:
      return Colors.yellow;
    case ConnectionStatus.waitingForAgent:
      return Colors.yellow;
    case ConnectionStatus.syncing:
      return Colors.yellow;
    case ConnectionStatus.connected:
      return Colors.green;
  }
}

/// 6×6 status dot, no text. Sits next to [KttyTitle] in the appBar.
/// The dot is intentionally tiny because the colour is now redundant
/// with the title's colour — it stays as a visual anchor that you can
/// glance at without parsing the title text.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final color = statusColor(session.status, session.relayReachable);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// "KTTY" title text, colour-shifted by current connection status. The
/// previous design had a separate `Connected` / `Disconnected` text
/// label that overflowed the appBar on a 360-dp phone. Now the title
/// itself carries the status, freeing horizontal space for the action
/// buttons (font zoom, info, etc.).
class KttyTitle extends StatelessWidget {
  const KttyTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final color = statusColor(session.status, session.relayReachable);
    return Text(
      'KTTY',
      style: TextStyle(
        fontSize: 13,
        color: color,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    );
  }
}
