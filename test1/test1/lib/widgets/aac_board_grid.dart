import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/board_provider.dart';
import '../providers/connection_provider.dart';
import 'symbol_tile.dart';

/// 2 × 2 grid of [SymbolTile] widgets driven by [BoardProvider].
///
/// Exposes [tileKeys] so that [AacBoardScreen] can perform gaze hit-testing
/// against each tile's [RenderBox] and drive dwell animations via
/// [SymbolTileState.startDwell] / [SymbolTileState.cancelDwell].
class AacBoardGrid extends StatefulWidget {
  const AacBoardGrid({super.key});

  @override
  State<AacBoardGrid> createState() => AacBoardGridState();
}

class AacBoardGridState extends State<AacBoardGrid> {
  static const _cols = 2;
  static const _rows = 2;

  late List<GlobalKey<SymbolTileState>> tileKeys;

  @override
  void initState() {
    super.initState();
    tileKeys = List.generate(
      _cols * _rows,
      (_) => GlobalKey<SymbolTileState>(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final symbols = context.watch<BoardProvider>().symbols;
    final dwellMs = context.watch<ConnectionProvider>().config.dwellDurationMs;

    const spacing = 8.0;
    const padding = 12.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth =
            (constraints.maxWidth - padding * 2 - spacing * (_cols - 1)) /
            _cols;
        final tileHeight =
            (constraints.maxHeight - padding * 2 - spacing * (_rows - 1)) /
            _rows;
        final aspectRatio = tileWidth / tileHeight;

        final itemCount = symbols.length.clamp(0, _cols * _rows);

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: aspectRatio,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            return SymbolTile(
              key: tileKeys[index],
              symbol: symbols[index],
              dwellDurationMs: dwellMs,
            );
          },
        );
      },
    );
  }
}
