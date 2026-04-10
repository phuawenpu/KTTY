import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/connection_state.dart';
import '../../state/session_state.dart';

class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final status = session.status;
    final relayReachable = session.relayReachable;
    final Color color;
    final String label;

    switch (status) {
      case ConnectionStatus.disconnected:
        if (relayReachable) {
          color = const Color(0xFF4488FF);
          label = 'Relay OK';
        } else {
          color = Colors.red;
          label = 'Disconnected';
        }
      case ConnectionStatus.connectingRelay:
        color = Colors.orange;
        label = 'Relay...';
      case ConnectionStatus.relayConnected:
        color = Colors.orange;
        label = 'Relay OK';
      case ConnectionStatus.handshaking:
        color = Colors.yellow;
        label = 'Handshake...';
      case ConnectionStatus.waitingForAgent:
        color = Colors.yellow;
        label = 'Waiting Agent';
      case ConnectionStatus.syncing:
        color = Colors.yellow;
        label = 'Syncing';
      case ConnectionStatus.connected:
        color = Colors.green;
        label = 'Connected';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 10),
        ),
      ],
    );
  }
}
