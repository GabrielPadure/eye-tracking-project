import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';

/// Entry screen shown when the app launches.
///
/// Provides Start (AAC Board), Calibrate, Settings, and a Quit button that
/// shuts the whole desktop bundle down (backend + browser tab).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _confirmQuit(BuildContext context) async {
    final conn = context.read<ConnectionProvider>();
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Quit AAC?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This stops the eye-tracking server and closes the app. '
          'You will need to relaunch the desktop app to start again.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Quit',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes != true) return;


    if (!conn.isConnected) {
      try {
        await conn.eyeTrackingService.connect(conn.config);
        // Brief wait so the upgrade completes before we send.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (_) {
      }
    }
    conn.eyeTrackingService.shutdownServer();
    // Give the WebSocket a moment to flush before we tear it down locally.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await conn.disconnect();

    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF16213E),
        title: Text('Server stopped',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'You can close this tab now.',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App logo placeholder
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: const Color(0xFF16213E),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.cyanAccent, width: 3),
              ),
              child: const Icon(
                Icons.remove_red_eye_outlined,
                size: 60,
                color: Colors.cyanAccent,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Eye Track AAC',
              style: TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Eye Tracking Interface',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
            const SizedBox(height: 48),
            _HomeButton(
              label: 'Start',
              icon: Icons.play_circle_outline,
              color: Colors.cyanAccent,
              onTap: () => Navigator.pushNamed(context, '/board'),
            ),
            const SizedBox(height: 16),
            _HomeButton(
              label: 'Calibrate',
              icon: Icons.adjust,
              color: Colors.orangeAccent,
              onTap: () => Navigator.pushNamed(context, '/calibration'),
            ),
            const SizedBox(height: 16),
            _HomeButton(
              label: 'Settings',
              icon: Icons.settings_outlined,
              color: Colors.white70,
              onTap: () => Navigator.pushNamed(context, '/settings'),
            ),
            const SizedBox(height: 16),
            _HomeButton(
              label: 'Quit',
              icon: Icons.power_settings_new,
              color: Colors.redAccent,
              onTap: () => _confirmQuit(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _HomeButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 64,
      child: ElevatedButton.icon(
        icon: Icon(icon, color: Colors.black),
        label: Text(
          label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: onTap,
      ),
    );
  }
}
