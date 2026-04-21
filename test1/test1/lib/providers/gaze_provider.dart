import 'package:flutter/foundation.dart';
import '../models/gaze_point.dart';

/// Holds the latest [GazePoint] received from [EyeTrackingService].
///
/// Widgets that need to react to gaze position (e.g. [GazeCursorOverlay])
/// watch this provider. [EyeTrackingService] calls [updateGaze] whenever
/// a new point arrives from the WebSocket stream.
class GazeProvider extends ChangeNotifier {
  GazePoint _gazePoint = GazePoint.center();

  GazePoint get gazePoint => _gazePoint;

  /// Called by [EyeTrackingService] on each incoming gaze message.
  void updateGaze(GazePoint point) {
    _gazePoint = point;
    notifyListeners();
  }

  /// Reset gaze to the screen centre — called on backend disconnect.
  void reset() {
    _gazePoint = GazePoint.center();
    notifyListeners();
  }
}
