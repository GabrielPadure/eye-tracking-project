import 'package:flutter/foundation.dart';

import '../data/sample_symbols.dart';
import '../models/aac_symbol.dart';
import '../services/tts_service.dart';

/// Holds the current AAC symbol board state: the list of visible symbols
/// and the last selected symbol. Also triggers TTS on selection.
///
/// -- INTEGRATION NOTES --
/// • Call [loadBoard] with real Cboard symbols once the Cboard API is wired in.
/// • [selectSymbol] fires whenever the user's gaze dwells on a [SymbolTile]
///   for the configured dwell duration.
class BoardProvider extends ChangeNotifier {
  final TtsService _tts;

  List<AacSymbol> _symbols;
  AacSymbol? _lastSelected;

  BoardProvider({required TtsService tts})
      : _tts = tts,
        _symbols = List.of(sampleSymbols);

  List<AacSymbol> get symbols => _symbols;
  AacSymbol? get lastSelected => _lastSelected;

  /// Called by [SymbolTile] when dwell is complete.
  Future<void> selectSymbol(AacSymbol symbol) async {
    _lastSelected = symbol;
    notifyListeners();
    await _tts.speak(symbol.label);
    debugPrint('[BoardProvider] Selected: ${symbol.label}');
  }

  /// Replace the board with a new set of symbols (e.g. from Cboard API).
  /// TODO: Implement Cboard category navigation using this method.
  void loadBoard(List<AacSymbol> symbols) {
    _symbols = symbols;
    _lastSelected = null;
    notifyListeners();
  }
}
