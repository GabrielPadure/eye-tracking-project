import 'package:flutter/material.dart';

import 'screens/aac_board_screen.dart';
import 'screens/calibration_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';

/// Root MaterialApp with named routes and the eye-friendly dark colour scheme.
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eye Track AAC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
        cardColor: const Color(0xFF16213E),
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyanAccent,
          secondary: Colors.orangeAccent,
          surface: Color(0xFF16213E),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/board': (_) => const AacBoardScreen(),
        '/calibration': (_) => const CalibrationScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }
}
