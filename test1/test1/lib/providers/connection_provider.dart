import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/backend_config.dart';
import '../services/eye_tracking_service.dart';
import '../services/gaze_simulator_service.dart';
import 'gaze_provider.dart';

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

  /// Update connection settings. Does NOT reconnect automatically.
  void updateConfig(BackendConfig config) {
    _config = config;
    notifyListeners();
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
