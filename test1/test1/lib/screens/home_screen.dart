import 'package:flutter/material.dart';

/// Entry screen shown when the app launches.
///
/// Provides three navigation buttons: Start (AAC Board), Calibrate, Settings.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
              'iPad Eye Tracking Interface',
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
