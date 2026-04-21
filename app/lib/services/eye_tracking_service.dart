import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/backend_config.dart';
import '../models/gaze_point.dart';

/// Manages the WebSocket connection to the Python/MediaPipe backend and
/// surfaces a [gazeStream] of normalised [GazePoint] values.
///
/// -- INTEGRATION NOTES --
/// • Call [connect] with a [BackendConfig] once the backend is running.
/// • The backend should send JSON messages in the format:
///     {"x": 0.45, "y": 0.62}
///   where x/y are normalised screen coordinates (0.0 – 1.0).
/// • Add reconnection logic inside [_onDone] when the backend is stable.
class EyeTrackingService {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  final StreamController<GazePoint> _gazeStreamController =
      StreamController<GazePoint>.broadcast();

  /// Stream of [GazePoint] values emitted as gaze data arrives from the backend.
  Stream<GazePoint> get gazeStream => _gazeStreamController.stream;

  /// Connect to the backend WebSocket server described by [config].
  Future<void> connect(BackendConfig config) async {
    await disconnect(); // clean up any existing connection
    try {
      _channel = WebSocketChannel.connect(Uri.parse(config.wsUrl));
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      debugPrint('[EyeTrackingService] Connected → ${config.wsUrl}');
    } catch (e) {
      debugPrint('[EyeTrackingService] Connection failed: $e');
    }
  }

  /// Close the WebSocket connection gracefully.
  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    debugPrint('[EyeTrackingService] Disconnected');
  }

  // ---------------------------------------------------------------------------
  // Private handlers
  // ---------------------------------------------------------------------------

  /// TODO: Adjust the JSON key names to match the actual backend message format.
  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final point = GazePoint(
        x: (data['x'] as num).toDouble().clamp(0.0, 1.0),
        y: (data['y'] as num).toDouble().clamp(0.0, 1.0),
        timestamp: DateTime.now(),
      );
      _gazeStreamController.add(point);
    } catch (e) {
      debugPrint('[EyeTrackingService] Failed to parse message: $e');
    }
  }

  void _onError(Object error) {
    debugPrint('[EyeTrackingService] WebSocket error: $error');
    // TODO: Notify ConnectionProvider of the error state.
  }

  void _onDone() {
    debugPrint('[EyeTrackingService] WebSocket closed by server');
    // TODO: Trigger reconnection attempt here.
  }

  void dispose() {
    disconnect();
    _gazeStreamController.close();
  }
}
