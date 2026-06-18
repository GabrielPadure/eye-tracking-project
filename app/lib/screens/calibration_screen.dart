import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connection_provider.dart';
import '../services/eye_tracking_service.dart';

/// Eye-tracking calibration screen.
///
/// Calibration is driven by the Python backend, but the app renders the
/// targets locally using positions from the backend. This screen triggers the
/// calibration run and shows progress until completion.
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
  String _phase = '';
  double? _targetX;
  double? _targetY;
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
    if (!conn.isConnected) {
      _showSnack('Connect to the backend before calibrating.');
      return;
    }
    setState(() {
      _isRunning = true;
      _statusText = 'Waiting for backend…';
      _point = 0;
      _total = 0;
      _phase = '';
      _targetX = null;
      _targetY = null;
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
          _phase = ev.phase;
          final hasTarget = (ev.phase == 'calibrating' || ev.phase == 'bias') &&
              ev.x != null && ev.y != null;
          _targetX = hasTarget ? ev.x : null;
          _targetY = hasTarget ? ev.y : null;
          if (ev.phase == 'positioning') {
            _statusText = 'Positioning — align your face and hold still';
          } else {
            final phaseLabel = ev.phase == 'bias' ? 'Bias check' : 'Calibrating';
            _statusText = '$phaseLabel — point ${ev.point} of ${ev.total}';
          }
        });
        break;
      case CalibrationEventType.done:
        setState(() {
          _isRunning = false;
          _statusText = 'Calibration complete';
          _phase = '';
          _targetX = null;
          _targetY = null;
        });
        _showDoneDialog();
        break;
      case CalibrationEventType.failed:
        setState(() {
          _isRunning = false;
          _statusText = 'Calibration failed: ${ev.reason ?? "unknown"}';
          _phase = '';
          _targetX = null;
          _targetY = null;
        });
        _showSnack(_statusText);
        break;
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showDoneDialog() {
    int secondsLeft = 3;
    Timer? timer;

    void goToBoard(BuildContext dialogCtx) {
      timer?.cancel();
      if (Navigator.canPop(dialogCtx)) Navigator.pop(dialogCtx);
      if (!mounted) return;
      // Resume gaze streaming after calibration finishes.
      _service.startStream();
      Navigator.pushReplacementNamed(context, '/board');
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // Start the auto-advance countdown the first time this rebuilds.
            timer ??= Timer.periodic(const Duration(seconds: 1), (t) {
              if (secondsLeft <= 1) {
                goToBoard(dialogCtx);
                return;
              }
              setDialogState(() => secondsLeft--);
            });
            return AlertDialog(
              backgroundColor: const Color(0xFF16213E),
              title: const Text(
                'Calibration Complete',
                style: TextStyle(color: Colors.white),
              ),
              content: Text(
                'Going to the board in $secondsLeft…',
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white54),
                  ),
                  onPressed: () {
                    timer?.cancel();
                    Navigator.pop(dialogCtx);
                  },
                ),
                TextButton(
                  child: const Text(
                    'Go now',
                    style: TextStyle(color: Colors.cyanAccent),
                  ),
                  onPressed: () => goToBoard(dialogCtx),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => timer?.cancel());
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final hasTarget =
                _isRunning && _targetX != null && _targetY != null;
            final clampedX = (_targetX ?? 0.5).clamp(0.0, 1.0);
            final clampedY = (_targetY ?? 0.5).clamp(0.0, 1.0);
            final dotColor =
                _phase == 'bias' ? Colors.greenAccent : Colors.cyanAccent;
            const double dotSize = 36.0;
            const double dotInner = 10.0;

            return Stack(
              children: [
                if (hasTarget)
                  Positioned(
                    left: clampedX * width - dotSize / 2,
                    top: clampedY * height - dotSize / 2,
                    child: IgnorePointer(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: dotSize,
                            height: dotSize,
                            decoration: BoxDecoration(
                              color: dotColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Container(
                            width: dotInner,
                            height: dotInner,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.remove_red_eye,
                            size: 72, color: Colors.cyanAccent),
                        const SizedBox(height: 16),
                        Text(
                          _statusText,
                          style:
                              const TextStyle(color: Colors.white, fontSize: 20),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
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
                            'Follow the dots on this screen with your eyes.',
                            style: TextStyle(color: Colors.white54),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 28),
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
              ],
            );
          },
        ),
      ),
    );
  }
}
