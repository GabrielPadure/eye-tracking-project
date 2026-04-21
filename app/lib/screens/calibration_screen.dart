import 'dart:async';

import 'package:flutter/material.dart';

/// Eye-tracking calibration screen.
///
/// Animates a pulsing target dot through 9 screen positions (3×3 grid).
/// The user follows the dot with their eyes while the Python backend
/// records the raw gaze coordinates to build its calibration model.
///
/// -- INTEGRATION NOTES --
/// At each position, call the backend calibration endpoint before advancing:
///   await eyeTrackingService.sendCalibrationPoint(index, alignment);
/// Wait for an acknowledgement before calling [Future.delayed].
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen>
    with SingleTickerProviderStateMixin {
  // 9-point calibration grid
  static const List<Alignment> _points = [
    Alignment.topLeft,
    Alignment.topCenter,
    Alignment.topRight,
    Alignment.centerLeft,
    Alignment.center,
    Alignment.centerRight,
    Alignment.bottomLeft,
    Alignment.bottomCenter,
    Alignment.bottomRight,
  ];

  int _currentIndex = 0;
  bool _isRunning = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  Future<void> _startCalibration() async {
    setState(() {
      _isRunning = true;
      _currentIndex = 0;
    });

    for (int i = 0; i < _points.length; i++) {
      if (!mounted) return;
      setState(() => _currentIndex = i);
      // TODO: Send calibration point to backend and await acknowledgement.
      await Future.delayed(const Duration(milliseconds: 1800));
    }

    if (!mounted) return;
    setState(() => _isRunning = false);
    _showDoneDialog();
  }

  void _showDoneDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          'Calibration Complete',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'All 9 calibration points captured.\n'
          'TODO: Validate accuracy score from the backend before proceeding.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            child: const Text(
              'Go to Board',
              style: TextStyle(color: Colors.cyanAccent),
            ),
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushReplacementNamed(context, '/board');
            },
          ),
          TextButton(
            child: const Text(
              'Retry',
              style: TextStyle(color: Colors.orangeAccent),
            ),
            onPressed: () {
              Navigator.pop(context);
              _startCalibration();
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Instructions
          Positioned(
            top: 20,
            left: 0,
            right: 0,
            child: Text(
              _isRunning
                  ? 'Follow the dot with your eyes  '
                      '(${_currentIndex + 1} / ${_points.length})'
                  : 'Press Start to begin 9-point calibration',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),

          // Animated calibration dot
          if (_isRunning)
            AnimatedAlign(
              alignment: _points[_currentIndex],
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    final size = 40 + _pulseController.value * 10;
                    final opacity = 0.4 + _pulseController.value * 0.5;
                    return Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.cyanAccent.withValues(alpha: opacity),
                        border: Border.all(color: Colors.cyanAccent, width: 3),
                      ),
                    );
                  },
                ),
              ),
            ),

          // Action buttons
          Positioned(
            bottom: 32,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_isRunning)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Calibration'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 16),
                    ),
                    onPressed: _startCalibration,
                  ),
                const SizedBox(width: 16),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
