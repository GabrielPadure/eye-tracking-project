import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/sample_symbols.dart';
import '../models/aac_symbol.dart';
import '../services/tts_service.dart';

const _kPrefSelectedIds = 'board_selected_ids';
const int boardSlotCount = 6;

/// Holds the AAC board state: the catalog of available symbols, the six
/// currently-selected symbol ids (one per grid slot, in order), and the last
/// selected symbol. Triggers TTS on selection.
///
/// Selection is persisted to [SharedPreferences] so the user's board layout
/// survives app restarts.
class BoardProvider extends ChangeNotifier {
  final TtsService _tts;

  /// Six symbol ids in slot order (top-left, top-middle, top-right,
  /// bottom-left, bottom-middle, bottom-right). Always length [boardSlotCount].
  List<String> _selectedIds = List.of(defaultSelectedIds);
  AacSymbol? _lastSelected;

  BoardProvider({required TtsService tts}) : _tts = tts;

  @override
  void dispose() {
    // Owned by this provider, so release it here. Fire-and-forget — the
    // async TTS stop is on its way out and we just want to drop the
    // platform handle so the engine can exit cleanly.
    _tts.dispose();
    super.dispose();
  }

  /// Full catalog of pickable symbols.
  List<AacSymbol> get catalog => symbolCatalog;

  /// Six symbols currently shown on the board, in slot order.
  List<AacSymbol> get symbols =>
      _selectedIds.map(_lookupOrFallback).toList(growable: false);

  /// Symbol ids in slot order (mainly for the editor UI).
  List<String> get selectedIds => List.unmodifiable(_selectedIds);

  AacSymbol? get lastSelected => _lastSelected;

  /// Called by [SymbolTile] when dwell is complete.
  Future<void> selectSymbol(AacSymbol symbol) async {
    _lastSelected = symbol;
    notifyListeners();
    await _tts.speak(symbol.label);
    debugPrint('[BoardProvider] Selected: ${symbol.label}');
  }

  /// Assign [symbolId] to grid slot [slotIndex] (0..5). Persists immediately.
  Future<void> setSlot(int slotIndex, String symbolId) async {
    if (slotIndex < 0 || slotIndex >= boardSlotCount) return;
    if (_lookup(symbolId) == null) return; // unknown id — ignore
    if (_selectedIds[slotIndex] == symbolId) return;
    _selectedIds[slotIndex] = symbolId;
    notifyListeners();
    await _persist();
  }

  /// Reset the board to [defaultSelectedIds]. Persists immediately.
  Future<void> resetToDefault() async {
    _selectedIds = List.of(defaultSelectedIds);
    _lastSelected = null;
    notifyListeners();
    await _persist();
  }

  /// Load persisted selection from disk. Call once at app startup before the
  /// board screen renders.
  Future<void> loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_kPrefSelectedIds);
      if (saved == null || saved.length != boardSlotCount) return;
      // Drop any ids that have since been removed from the catalog; backfill
      // from the defaults so we always end up with [boardSlotCount] entries.
      final cleaned = <String>[];
      for (var i = 0; i < boardSlotCount; i++) {
        final id = saved[i];
        cleaned.add(_lookup(id) != null ? id : defaultSelectedIds[i]);
      }
      _selectedIds = cleaned;
      notifyListeners();
    } catch (e) {
      debugPrint('[BoardProvider] Failed to load selection: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPrefSelectedIds, _selectedIds);
    } catch (e) {
      debugPrint('[BoardProvider] Failed to persist selection: $e');
    }
  }

  AacSymbol? _lookup(String id) {
    for (final s in symbolCatalog) {
      if (s.id == id) return s;
    }
    return null;
  }

  // Fallback should be unreachable once `loadPersisted` has run, but keeps
  // the UI safe if a slot somehow points at a missing id.
  AacSymbol _lookupOrFallback(String id) =>
      _lookup(id) ?? symbolCatalog.first;
}
