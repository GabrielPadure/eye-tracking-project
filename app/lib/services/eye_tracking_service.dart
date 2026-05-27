import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../models/backend_config.dart';
import '../models/gaze_point.dart';

/// Backend calibration lifecycle events forwarded to the UI.
enum CalibrationEventType { progress, done, failed }

class CalibrationEvent {
  final CalibrationEventType type;
  final int point;
  final int total;
  final String phase;
  final String? reason;

  const CalibrationEvent({
    required this.type,
    this.point = 0,
    this.total = 0,
    this.phase = '',
    this.reason,
  });
}

/// Manages the WebSocket connection to the Python/MediaPipe backend and
/// surfaces a [gazeStream] of normalised [GazePoint] values plus a
/// [calibrationStream] of backend-driven calibration events.
///
/// Wire protocol — server → client:
///   {"x": 0.45, "y": 0.62, "confidence": 0.92, "blink": false}
///   {"type": "calibration_progress", "phase": "calibrating", "point": 3, "total": 13}
///   {"type": "calibration_done"}
///   {"type": "calibration_failed", "reason": "..."}
///
/// Wire protocol — client → server:
///   {"type": "start_calibration"}
///   {"type": "start_stream"}
///   {"type": "stop_stream"}
class EyeTrackingService {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  BackendConfig? _lastConfig;

  // Auto-reconnect state
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const _reconnectBaseMs = 1000;
  static const _reconnectMaxMs = 30000;
  bool _intentionallyClosed = false;

  final StreamController<GazePoint> _gazeStreamController =
      StreamController<GazePoint>.broadcast();
  final StreamController<CalibrationEvent> _calibrationController =
      StreamController<CalibrationEvent>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  Stream<GazePoint> get gazeStream => _gazeStreamController.stream;
  Stream<CalibrationEvent> get calibrationStream =>
      _calibrationController.stream;

  /// Emits `true` when a fresh WebSocket is established, `false` when it
  /// drops. Used by [ConnectionProvider] to drive [ConnectionStatus].
  Stream<bool> get connectionStream => _connectionController.stream;

  bool get isConnected => _channel != null;

  /// Connect to the backend WebSocket server described by [config].
  Future<void> connect(BackendConfig config) async {
    _intentionallyClosed = false;
    _lastConfig = config;
    await _disconnectInternal();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(config.wsUrl));
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _reconnectAttempt = 0;
      _connectionController.add(true);
      debugPrint('[EyeTrackingService] Connected → ${config.wsUrl}');
    } catch (e) {
      debugPrint('[EyeTrackingService] Connection failed: $e');
      _scheduleReconnect();
    }
  }

  /// Close the WebSocket connection gracefully (no reconnect).
  Future<void> disconnect() async {
    _intentionallyClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _disconnectInternal();
  }

  Future<void> _disconnectInternal() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
  }

  /// Send a JSON command to the backend.
  void _send(Map<String, dynamic> payload) {
    final sink = _channel?.sink;
    if (sink == null) {
      debugPrint(
          '[EyeTrackingService] Cannot send — socket not connected: $payload');
      return;
    }
    sink.add(jsonEncode(payload));
  }

  /// Ask the backend to run its calibration routine. Progress and completion
  /// events are emitted on [calibrationStream].
  void startCalibration() => _send({'type': 'start_calibration'});

  /// Resume gaze streaming after calibration / pause.
  void startStream() => _send({'type': 'start_stream'});

  /// Pause gaze streaming.
  void stopStream() => _send({'type': 'stop_stream'});

  // ---------------------------------------------------------------------------
  // Private handlers
  // ---------------------------------------------------------------------------

  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final msgType = data['type'] as String?;
      if (msgType != null) {
        _handleControlMessage(msgType, data);
        return;
      }
      // No `type` field → assume it's a gaze frame.
      final point = GazePoint(
        x: (data['x'] as num).toDouble().clamp(0.0, 1.0),
        y: (data['y'] as num).toDouble().clamp(0.0, 1.0),
        confidence: (data['confidence'] as num?)?.toDouble() ?? 1.0,
        blink: data['blink'] as bool? ?? false,
        timestamp: DateTime.now(),
      );
      _gazeStreamController.add(point);
    } catch (e) {
      debugPrint('[EyeTrackingService] Failed to parse message: $e');
    }
  }

  void _handleControlMessage(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'calibration_progress':
        _calibrationController.add(CalibrationEvent(
          type: CalibrationEventType.progress,
          phase: data['phase'] as String? ?? '',
          point: (data['point'] as num?)?.toInt() ?? 0,
          total: (data['total'] as num?)?.toInt() ?? 0,
        ));
        break;
      case 'calibration_done':
        _calibrationController.add(
            const CalibrationEvent(type: CalibrationEventType.done));
        break;
      case 'calibration_failed':
        _calibrationController.add(CalibrationEvent(
          type: CalibrationEventType.failed,
          reason: data['reason'] as String?,
        ));
        break;
      default:
        debugPrint('[EyeTrackingService] Unknown control message: $type');
    }
  }

  void _onError(Object error) {
    debugPrint('[EyeTrackingService] WebSocket error: $error');
    _connectionController.add(false);
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('[EyeTrackingService] WebSocket closed by server');
    _connectionController.add(false);
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_intentionallyClosed || _lastConfig == null) return;
    _reconnectTimer?.cancel();
    final delayMs = (_reconnectBaseMs * (1 << _reconnectAttempt))
        .clamp(_reconnectBaseMs, _reconnectMaxMs);
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 6); // cap exponent
    debugPrint(
        '[EyeTrackingService] Reconnecting in ${delayMs}ms (attempt $_reconnectAttempt)');
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_intentionallyClosed || _lastConfig == null) return;
      connect(_lastConfig!);
    });
  }

  void dispose() {
    disconnect();
    _gazeStreamController.close();
    _calibrationController.close();
    _connectionController.close();
  }
}
