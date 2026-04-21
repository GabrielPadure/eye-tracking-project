import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/aac_symbol.dart';
import '../providers/board_provider.dart';

/// A single AAC communication symbol tile.
///
/// Displays a coloured image placeholder (swap in [AacSymbol.imagePath] when
/// real Cboard assets are available), a text label, and a circular progress
/// ring that fills during gaze dwell.
///
/// Interaction:
/// • On desktop/dev: hover starts dwell, mouse exit cancels it.
/// • On iPad: no hover, so gaze dwell is driven by the backend. Wire
///   [startDwell] / [cancelDwell] to the gaze-hit-test logic in [AacBoardScreen].
///   For now, a tap-and-hold gesture provides a fallback for manual testing.
class SymbolTile extends StatefulWidget {
  final AacSymbol symbol;
  final int dwellDurationMs;

  const SymbolTile({
    super.key,
    required this.symbol,
    this.dwellDurationMs = 1500,
  });

  @override
  State<SymbolTile> createState() => SymbolTileState();
}

/// Public state class so that [AacBoardScreen] can obtain a typed
/// [GlobalKey<SymbolTileState>] and call [startDwell] / [cancelDwell]
/// from gaze hit-test logic.
class SymbolTileState extends State<SymbolTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _dwellController;
  bool _isDwelling = false;

  @override
  void initState() {
    super.initState();
    _dwellController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.dwellDurationMs),
    )..addStatusListener(_onDwellStatusChanged);
  }

  // ---------------------------------------------------------------------------
  // Dwell control — call these from gaze-hit-test logic when backend is ready.
  // ---------------------------------------------------------------------------

  void startDwell() {
    if (_isDwelling) return;
    _isDwelling = true;
    _dwellController.forward(from: 0);
  }

  void cancelDwell() {
    if (!_isDwelling) return;
    _isDwelling = false;
    _dwellController.stop();
    _dwellController.reset();
  }

  void _onDwellStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _isDwelling = false;
      _dwellController.reset();
      context.read<BoardProvider>().selectSymbol(widget.symbol);
    }
  }

  @override
  void dispose() {
    _dwellController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSelected =
        context.watch<BoardProvider>().lastSelected?.id == widget.symbol.id;

    return GestureDetector(
      // Tap-and-hold fallback for manual testing without eye tracking.
      onTapDown: (_) => startDwell(),
      onTapUp: (_) => cancelDwell(),
      onTapCancel: cancelDwell,
      child: MouseRegion(
        // Hover-to-dwell simulation for desktop development.
        onEnter: (_) => startDwell(),
        onExit: (_) => cancelDwell(),
        child: AnimatedBuilder(
          animation: _dwellController,
          builder: (context, _) {
            return Card(
              elevation: isSelected ? 8 : 2,
              color: isSelected
                  ? widget.symbol.color.withValues(alpha: 0.2)
                  : Theme.of(context).cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: isSelected
                    ? BorderSide(color: widget.symbol.color, width: 3)
                    : BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Symbol content
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: _ImagePlaceholder(color: widget.symbol.color),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.symbol.label,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                    // Dwell progress ring
                    if (_dwellController.value > 0)
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: _dwellController.value,
                          strokeWidth: 5,
                          color: widget.symbol.color,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Coloured placeholder shown until real Cboard images are loaded.
/// TODO: Replace with Image.asset(symbol.imagePath) or a network image widget.
class _ImagePlaceholder extends StatelessWidget {
  final Color color;

  const _ImagePlaceholder({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Icon(Icons.image_outlined, size: 40, color: color),
      ),
    );
  }
}
