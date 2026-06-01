import 'package:flutter/material.dart';

import '../models/aac_symbol.dart';

/// Renders an AAC symbol's image from `assets/symbols/<id>.png`.
///
/// Falls back to a coloured icon placeholder when the asset file is missing,
/// so the app stays functional during the rollout where some symbols still
/// don't have art. To add real images, drop `<symbol-id>.png` files into
/// `app/assets/symbols/` and rebuild — no code changes needed.
class SymbolImage extends StatelessWidget {
  final AacSymbol symbol;

  /// Optional fixed size (square). When null, the widget fills its parent's
  /// constraints — use this inside an `Expanded` / `SizedBox`.
  final double? size;

  final BoxFit fit;

  const SymbolImage({
    super.key,
    required this.symbol,
    this.size,
    this.fit = BoxFit.contain,
  });

  String get _path => 'assets/symbols/${symbol.id}.png';

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      _path,
      width: size,
      height: size,
      fit: fit,
      // gaplessPlayback avoids the brief blank-frame when an image is
      // replaced (e.g. when the editor swaps a slot).
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => _SymbolFallback(symbol: symbol, size: size),
    );
  }
}

class _SymbolFallback extends StatelessWidget {
  final AacSymbol symbol;
  final double? size;

  const _SymbolFallback({required this.symbol, this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: symbol.color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          color: symbol.color,
          size: size != null ? size! * 0.6 : 40,
        ),
      ),
    );
  }
}
