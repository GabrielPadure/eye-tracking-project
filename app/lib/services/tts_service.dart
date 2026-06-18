import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Wrapper around flutter_tts that speaks selected AAC symbol labels aloud.
///
/// -- INTEGRATION NOTES --
/// • Call [init] once at app startup (inside main()).
/// • Adjust [setLanguage] and [setSpeechRate] to user preference in Settings.
/// • On iOS, TTS requires the app to have audio session entitlements enabled
///   in Xcode if background audio is needed.
class TtsService {
  final FlutterTts _tts = FlutterTts();

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    debugPrint('[TtsService] Initialized');
  }

  /// Speak [text] aloud. Any currently playing speech is stopped first.
  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
    debugPrint('[TtsService] Speaking: "$text"');
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
