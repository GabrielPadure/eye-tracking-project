import 'package:flutter/material.dart';

/// Represents a single AAC communication symbol on the board.
///
/// [imagePath] is null for placeholder symbols; set it when real
/// Cboard assets are integrated.
class AacSymbol {
  final String id;
  final String label;
  final String? imagePath;
  final String category;

  /// Placeholder background color shown until real image assets are added.
  final Color color;

  const AacSymbol({
    required this.id,
    required this.label,
    this.imagePath,
    required this.category,
    required this.color,
  });
}
