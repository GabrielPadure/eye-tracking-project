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

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gazeProvider),
        ChangeNotifierProvider(
          create: (_) => ConnectionProvider(
            service: eyeTrackingService,
            gazeProvider: gazeProvider,
            config: const BackendConfig(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => BoardProvider(tts: ttsService),
        ),
      ],
      child: const App(),
    ),
  );
}
