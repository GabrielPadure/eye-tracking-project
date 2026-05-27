import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/backend_config.dart';
import '../services/eye_tracking_service.dart';
import '../services/gaze_simulator_service.dart';
import 'gaze_provider.dart';

// SharedPreferences keys for BackendConfig persistence.
const _kPrefHost = 'backend_host';
const _kPrefPort = 'backend_port';
const _kPrefDwell = 'dwell_duration_ms';

enum ConnectionStatus { disconnected, connecting, connected }

/// Which input source is currently driving [GazeProvider].
enum GazeInputMode {
  /// Nothing active — gaze cursor is centred.
  none,

  /// Mouse pointer position drives the gaze cursor (desktop / web dev).
  mouse,

  /// [GazeSimulatorService] drives the gaze cursor with a random-walk model.
  simulator,

  /// Live WebSocket connection to the Python/MediaPipe backend.
  websocket,
}

/// Manages the WebSocket connection lifecycle and exposes [status] to the UI.
///
/// Consumers listen to [status] for visual feedback (e.g. [ConnectionStatusBadge]).
/// [GazeProvider] is wired here so that incoming gaze data is forwarded
/// automatically while connected.
class ConnectionProvider extends ChangeNotifier {
  final EyeTrackingService _service;
  final GazeProvider _gazeProvider;
  final GazeSimulatorService _simulator = GazeSimulatorService();

  BackendConfig _config;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  StreamSubscription<dynamic>? _gazeSubscription;
  bool _simulating = false;
  GazeInputMode _inputMode = GazeInputMode.none;

  ConnectionProvider({
    required EyeTrackingService service,
    required GazeProvider gazeProvider,
    BackendConfig config = const BackendConfig(),
  })  : _service = service,
        _gazeProvider = gazeProvider,
        _config = config;

  ConnectionStatus get status => _status;
  BackendConfig get config => _config;
  bool get isConnected => _status == ConnectionStatus.connected;
  bool get isSimulating => _simulating;
  GazeInputMode get inputMode => _inputMode;

  /// Direct handle to the WebSocket service — exposed so screens (e.g.
  /// [CalibrationScreen]) can subscribe to calibration events and send
  /// control messages.
  EyeTrackingService get eyeTrackingService => _service;

  /// Open the WebSocket connection and start forwarding gaze data.
  Future<void> connect() async {
    if (_status != ConnectionStatus.disconnected) await _stopAll();
    _inputMode = GazeInputMode.websocket;
    _setStatus(ConnectionStatus.connecting);

    await _service.connect(_config);
    _gazeSubscription = _service.gazeStream.listen(_gazeProvider.updateGaze);

    _setStatus(ConnectionStatus.connected);
  }

  /// Close the connection and reset the gaze cursor.
  Future<void> disconnect() async {
    await _stopAll();
  }

  /// Update connection settings. Does NOT reconnect automatically. The new
  /// values are persisted to [SharedPreferences] so they survive app restarts.
  void updateConfig(BackendConfig config) {
    _config = config;
    _persistConfig();
    notifyListeners();
  }

  /// Load any previously saved [BackendConfig] from disk and replace the
  /// current config. Safe to call at app startup; if no saved values exist
  /// the constructor default is kept.
  Future<void> loadPersistedConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString(_kPrefHost);
      final port = prefs.getInt(_kPrefPort);
      final dwell = prefs.getInt(_kPrefDwell);
      if (host == null && port == null && dwell == null) return;
      _config = _config.copyWith(
        host: host,
        port: port,
        dwellDurationMs: dwell,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[ConnectionProvider] Failed to load config: $e');
    }
  }

  Future<void> _persistConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefHost, _config.host);
      await prefs.setInt(_kPrefPort, _config.port);
      await prefs.setInt(_kPrefDwell, _config.dwellDurationMs);
    } catch (e) {
      debugPrint('[ConnectionProvider] Failed to persist config: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Mouse mode
  // ---------------------------------------------------------------------------

  /// Switch to mouse-tracking mode.
  ///
  /// No stream subscription is needed — [AacBoardScreen] feeds normalised
  /// mouse positions directly into [GazeProvider.updateGaze] via a
  /// [MouseRegion] overlay.  This method just sets the mode flag so the UI
  /// knows to enable that overlay.
  Future<void> startMouseMode() async {
    if (_inputMode == GazeInputMode.mouse) return;
    await _stopAll();
    _inputMode = GazeInputMode.mouse;
    _setStatus(ConnectionStatus.connected);
  }

  Future<void> stopMouseMode() async {
    if (_inputMode != GazeInputMode.mouse) return;
    await _stopAll();
  }

  // ---------------------------------------------------------------------------
  // Simulation
  // ---------------------------------------------------------------------------

  /// Start the gaze simulator, feeding fake [GazePoint]s through the same
  /// pipeline as the real WebSocket connection.
  Future<void> startSimulation() async {
    if (_inputMode == GazeInputMode.simulator) return;
    await _stopAll();

    _simulating = true;
    _inputMode = GazeInputMode.simulator;
    _setStatus(ConnectionStatus.connected);

    _gazeSubscription =
        _simulator.gazeStream.listen(_gazeProvider.updateGaze);
    _simulator.start();
  }

  /// Stop the gaze simulator and reset the cursor.
  Future<void> stopSimulation() async {
    if (_inputMode != GazeInputMode.simulator) return;
    await _stopAll();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Tears down whichever mode is currently running and resets state.
  Future<void> _stopAll() async {
    _simulator.stop();
    await _gazeSubscription?.cancel();
    _gazeSubscription = null;
    if (_inputMode == GazeInputMode.websocket) {
      await _service.disconnect();
    }
    _gazeProvider.reset();
    _simulating = false;
    _inputMode = GazeInputMode.none;
    _setStatus(ConnectionStatus.disconnected);
  }

  void _setStatus(ConnectionStatus s) {
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _gazeSubscription?.cancel();
    _simulator.dispose();
    _service.dispose();
    super.dispose();
  }
}
