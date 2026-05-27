/// Normalised gaze point received from the Python/MediaPipe backend.
///
/// [x] and [y] are in the range 0.0–1.0, where (0, 0) is the top-left
/// corner of the screen and (1, 1) is the bottom-right.
///
/// [confidence] is the pose-gate score from the backend (1.0 = head pose
/// is in the calibrated range; drops toward 0.0 as the head moves further
/// from the calibration distribution). [blink] is the EyeTrax blink flag.
class GazePoint {
  final double x;
  final double y;
  final double confidence;
  final bool blink;
  final DateTime timestamp;

  const GazePoint({
    required this.x,
    required this.y,
    required this.timestamp,
    this.confidence = 1.0,
    this.blink = false,
  });

  /// Returns a gaze point at the centre of the screen (used as the initial state).
  static GazePoint center() =>
      GazePoint(x: 0.5, y: 0.5, timestamp: DateTime.now());
}
