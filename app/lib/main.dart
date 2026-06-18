import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'models/backend_config.dart';
import 'providers/board_provider.dart';
import 'providers/connection_provider.dart';
import 'providers/gaze_provider.dart';
import 'services/eye_tracking_service.dart';
import 'services/tts_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to landscape for iPad use.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Initialise services.
  final eyeTrackingService = EyeTrackingService();
  final ttsService = TtsService();
  await ttsService.init();

  // Instantiate GazeProvider early so ConnectionProvider can wire into it.
  final gazeProvider = GazeProvider();
  final connectionProvider = ConnectionProvider(
    service: eyeTrackingService,
    gazeProvider: gazeProvider,
    config: const BackendConfig(),
  );
  // Restore any saved host/port/dwell before the UI renders the settings screen.
  await connectionProvider.loadPersistedConfig();

  unawaited(connectionProvider.connect());

  // Restore the user's selected board symbols before the board renders.
  final boardProvider = BoardProvider(tts: ttsService);
  await boardProvider.loadPersisted();

  // Release background resources (simulator Timer, WebSocket subscription,
  // TTS engine handle) when the OS signals app shutdown. 
  var disposed = false;
  void cleanup() {
    if (disposed) return;
    disposed = true;
    try { connectionProvider.dispose(); } catch (_) {} // disposes EyeTrackingService + simulator
    try { boardProvider.dispose();      } catch (_) {} // disposes TtsService
    try { gazeProvider.dispose();       } catch (_) {}
  }

  // AppLifecycleListener registers itself with WidgetsBinding on construction
  // and stays alive for the life of the process via that binding reference.
  final lifecycleListener = AppLifecycleListener(onDetach: cleanup);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gazeProvider),
        ChangeNotifierProvider.value(value: connectionProvider),
        ChangeNotifierProvider.value(value: boardProvider),
      ],
      child: const App(),
    ),
  );
}
