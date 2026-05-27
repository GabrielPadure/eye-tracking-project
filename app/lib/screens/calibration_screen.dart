import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';
import '../services/eye_tracking_service.dart';

/// Eye-tracking calibration screen.
///
/// Calibration is driven entirely by the Python backend (it opens a pygame
/// window on the laptop and runs the 13-point + 5-anchor passes). This screen
/// just triggers it and shows progress until the backend reports completion.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  bool _isRunning = false;
  String _statusText = 'Press Start to begin calibration';
  int _point = 0;
  int _total = 0;
  StreamSubscription<CalibrationEvent>? _sub;

  EyeTrackingService get _service =>
      context.read<ConnectionProvider>().eyeTrackingService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sub = _service.calibrationStream.listen(_onEvent);
    });
  }

  Future<void> _startCalibration() async {
    final conn = context.read<ConnectionProvider>();
    if (!conn.isConnected || conn.inputMode != GazeInputMode.websocket) {
      _showSnack(
        'Connect to the backend (WebSocket mode) before calibrating.',
      );
      return;
    }
    setState(() {
      _isRunning = true;
      _statusText = 'Waiting for backend…';
      _point = 0;
      _total = 0;
    });
    _service.startCalibration();
  }

  void _onEvent(CalibrationEvent ev) {
    if (!mounted) return;
    switch (ev.type) {
      case CalibrationEventType.progress:
        setState(() {
          _point = ev.point;
          _total = ev.total;
          final phaseLabel = ev.phase == 'bias' ? 'Bias check' : 'Calibrating';
          _statusText = '$phaseLabel — point ${ev.point} of ${ev.total}';
        });
        break;
      case CalibrationEventType.done:
        setState(() {
          _isRunning = false;
          _statusText = 'Calibration complete';
        });
        _showDoneDialog();
        break;
      case CalibrationEventType.failed:
        setState(() {
          _isRunning = false;
          _statusText = 'Calibration failed: ${ev.reason ?? "unknown"}';
        });
        _showSnack(_statusText);
        break;
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
          'The backend has finished calibration. You can now use the board.',
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
              // Resume gaze streaming after calibration finishes.
              _service.startStream();
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
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.remove_red_eye,
                  size: 80, color: Colors.cyanAccent),
              const SizedBox(height: 24),
              Text(
                _statusText,
                style: const TextStyle(color: Colors.white, fontSize: 20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_isRunning) ...[
                SizedBox(
                  width: 240,
                  child: LinearProgressIndicator(
                    value: (_total > 0) ? _point / _total : null,
                    color: Colors.cyanAccent,
                    backgroundColor: Colors.white12,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Follow the dots on the laptop screen with your eyes.',
                  style: TextStyle(color: Colors.white54),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 40),
              Row(
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
            ],
          ),
        ),
      ),
    );
  }
}
