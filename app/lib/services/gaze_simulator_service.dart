import 'dart:async';
import 'dart:math';

import '../models/gaze_point.dart';

/// Simulates realistic eye-tracking gaze data for development and testing.
///
/// The simulator runs a two-phase motion model:
///  1. **Saccade** — fast ballistic movement towards the next fixation target.
///  2. **Fixation** — small tremor/drift noise around the target for a
///     configurable dwell window.
///
/// Targets are 80 % drawn from the approximate symbol-grid centres and 20 %
/// from random screen positions (to exercise off-target behaviour).
///
/// Gaze points are emitted at ~30 fps through [gazeStream].
class GazeSimulatorService {
  static const _fps = 30;
  static const _intervalMs = 1000 ~/ _fps; // ≈ 33 ms per tick

  /// How long (ms) the simulated eye lingers on each fixation target.
  static const _fixationDurationMs = 2400;

  /// Maximum movement per frame during saccade (normalised units 0–1).
  static const _saccadeSpeedPerFrame = 0.045;

  /// Half-width of the Gaussian-ish noise added during fixation.
  static const _fixationNoiseRadius = 0.022;

  /// Approximate centres of the 2 × 2 symbol grid (normalised x, y).
  ///
  /// These match the visual layout: grid is below the ~50 px top bar, split
  /// evenly across the screen width.  The real hit-test in [AacBoardScreen]
  /// uses [RenderBox] measurements, so small inaccuracies here are fine.
  static const _symbolTargets = <(double, double)>[
    (0.27, 0.38), // top-left
    (0.73, 0.38), // top-right
    (0.27, 0.78), // bottom-left
    (0.73, 0.78), // bottom-right
  ];

  final _random = Random();
  final _controller = StreamController<GazePoint>.broadcast();

  Timer? _timer;
  double _x = 0.5;
  double _y = 0.5;
  double _targetX = 0.5;
  double _targetY = 0.5;
  int _fixationTicksLeft = 0;
  bool _isFixating = false;

  /// Broadcast stream of simulated [GazePoint]s (~30 fps).
  Stream<GazePoint> get gazeStream => _controller.stream;

  bool get isRunning => _timer != null;

  /// Start emitting simulated gaze data.
  void start() {
    if (_timer != null) return;
    _x = 0.5;
    _y = 0.5;
    _isFixating = false;
    _pickNextTarget();
    _timer = Timer.periodic(
      const Duration(milliseconds: _intervalMs),
      _tick,
    );
  }

  /// Stop emitting gaze data.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _tick(Timer _) {
    if (_isFixating) {
      // Micro-tremor / drift noise during fixation.
      _x = (_targetX + (_random.nextDouble() - 0.5) * 2 * _fixationNoiseRadius)
          .clamp(0.0, 1.0);
      _y = (_targetY + (_random.nextDouble() - 0.5) * 2 * _fixationNoiseRadius)
          .clamp(0.0, 1.0);
      _fixationTicksLeft--;
      if (_fixationTicksLeft <= 0) {
        _isFixating = false;
        _pickNextTarget();
      }
    } else {
      // Saccade: step towards target at constant speed.
      final dx = _targetX - _x;
      final dy = _targetY - _y;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist <= _saccadeSpeedPerFrame) {
        // Arrived — begin fixation.
        _x = _targetX;
        _y = _targetY;
        _isFixating = true;
        _fixationTicksLeft = (_fixationDurationMs / _intervalMs).round();
      } else {
        _x += (dx / dist) * _saccadeSpeedPerFrame;
        _y += (dy / dist) * _saccadeSpeedPerFrame;
      }
    }

    if (!_controller.isClosed) {
      _controller.add(GazePoint(x: _x, y: _y, timestamp: DateTime.now()));
    }
  }

  void _pickNextTarget() {
    if (_random.nextDouble() < 0.80) {
      // Fixate on a random symbol tile centre.
      final t = _symbolTargets[_random.nextInt(_symbolTargets.length)];
      _targetX = t.$1;
      _targetY = t.$2;
    } else {
      // Random off-symbol drift.
      _targetX = 0.05 + _random.nextDouble() * 0.90;
      _targetY = 0.05 + _random.nextDouble() * 0.90;
    }
  }
}
