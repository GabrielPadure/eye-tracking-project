import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/aac_symbol.dart';
import '../providers/board_provider.dart';
import 'symbol_image.dart';

/// A single AAC communication symbol tile.
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
                          child: SymbolImage(symbol: widget.symbol),
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

