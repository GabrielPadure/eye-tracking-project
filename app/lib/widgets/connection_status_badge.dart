import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';

/// Small badge displaying the current WebSocket connection status.
/// Shown in the top-right corner of [AacBoardScreen].
class ConnectionStatusBadge extends StatelessWidget {
  const ConnectionStatusBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.watch<ConnectionProvider>().status;

    final (color, label) = switch (status) {
      ConnectionStatus.connected => (Colors.greenAccent, 'Connected'),
      ConnectionStatus.connecting => (Colors.amber, 'Connecting…'),
      ConnectionStatus.disconnected => (Colors.redAccent, 'Disconnected'),
    };

    return GestureDetector(
      onTap: () {
        // Tap to toggle connection — useful for quick testing.
        final provider = context.read<ConnectionProvider>();
        if (provider.isConnected) {
          provider.disconnect();
        } else {
          provider.connect();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
