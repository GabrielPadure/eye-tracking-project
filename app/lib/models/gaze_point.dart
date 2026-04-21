/// Normalised gaze point received from the Python/MediaPipe backend.
///
/// [x] and [y] are in the range 0.0–1.0, where (0, 0) is the top-left
/// corner of the screen and (1, 1) is the bottom-right.
class GazePoint {
  final double x;
  final double y;
  final DateTime timestamp;

  const GazePoint({
    required this.x,
    required this.y,
    required this.timestamp,
  });

  /// Returns a gaze point at the centre of the screen (used as the initial state).
  static GazePoint center() =>
      GazePoint(x: 0.5, y: 0.5, timestamp: DateTime.now());
}
