import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/connection_state.dart';
import '../../state/session_state.dart';

class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.watch<SessionState>().status;
    final Color color;
    final String label;

    switch (status) {
      case ConnectionStatus.connected:
        color = Colors.green;
        label = 'Connected';
      case ConnectionStatus.syncing:
        color = Colors.yellow;
        label = 'Syncing';
      case ConnectionStatus.disconnected:
        color = Colors.red;
        label = 'Disconnected';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 12),
        ),
      ],
    );
  }
}
