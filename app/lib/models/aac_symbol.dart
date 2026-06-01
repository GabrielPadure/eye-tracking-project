import 'package:flutter/material.dart';

/// Represents a single AAC communication symbol on the board.
///
/// The image asset path is derived from [id] by convention:
/// `assets/symbols/<id>.png` (see [SymbolImage]). The [color] is used as a
/// tinted fallback when the asset is missing, and as accent colour on the
/// tile border / selection state.
class AacSymbol {
  final String id;
  final String label;
  final String category;

  /// Accent colour used for the tile border and the missing-asset fallback.
  final Color color;

  const AacSymbol({
    required this.id,
    required this.label,
    required this.category,
    required this.color,
  });
}
