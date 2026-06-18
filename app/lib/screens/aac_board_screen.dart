import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/board_provider.dart';
import '../providers/gaze_provider.dart';
import '../widgets/aac_board_grid.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/gaze_cursor_overlay.dart';
import '../widgets/symbol_tile.dart';

/// Main AAC communication board screen.

/// This screen listens to [GazeProvider] and performs a [RenderBox] hit-test
/// against each tile to drive [SymbolTileState.startDwell] /
/// [SymbolTileState.cancelDwell].
class AacBoardScreen extends StatefulWidget {
  const AacBoardScreen({super.key});

  @override
  State<AacBoardScreen> createState() => _AacBoardScreenState();
}

class _AacBoardScreenState extends State<AacBoardScreen> {
  final _gridKey = GlobalKey<AacBoardGridState>();

  GazeProvider? _gazeProvider;

  // Cached layout values — updated each build so the hit-test callback can
  // use them without a BuildContext.
  Size _cachedScreenSize = Size.zero;
  EdgeInsets _cachedSafeAreaPadding = EdgeInsets.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gazeProvider = context.read<GazeProvider>();
      _gazeProvider!.addListener(_onGazeUpdate);
    });
  }

  @override
  void dispose() {
    _gazeProvider?.removeListener(_onGazeUpdate);
    super.dispose();
  }

  void _onGazeUpdate() {
    final gaze = _gazeProvider?.gazePoint;
    if (gaze == null) return;

    // Confidence / blink gate: when the backend reports the head is outside
    // the calibrated range (or the user is blinking), cancel every dwell
    // instead of letting hit-tests trigger false selections.
    if (gaze.confidence < 0.5 || gaze.blink) {
      final gridState = _gridKey.currentState;
      if (gridState == null) return;
      for (final key in gridState.tileKeys) {
        key.currentState?.cancelDwell();
      }
      return;
    }

    // Convert normalised gaze (0–1) to global screen pixels, matching the
    // same coordinate mapping used by [GazeCursorOverlay].
    final safeLeft = _cachedSafeAreaPadding.left;
    final safeTop = _cachedSafeAreaPadding.top;
    final availW =
        _cachedScreenSize.width - _cachedSafeAreaPadding.horizontal;
    final availH =
        _cachedScreenSize.height - _cachedSafeAreaPadding.vertical;

    final gazePixel = Offset(
      safeLeft + gaze.x * availW,
      safeTop + gaze.y * availH,
    );

    final gridState = _gridKey.currentState;
    if (gridState == null) return;

    for (final key in gridState.tileKeys) {
      final renderBox =
          key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.attached) continue;

      final tileRect =
          renderBox.localToGlobal(Offset.zero) & renderBox.size;
      final tileState = key.currentState;
      if (tileState == null) continue;

      if (tileRect.contains(gazePixel)) {
        tileState.startDwell();
      } else {
        tileState.cancelDwell();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Cache layout data for the hit-test callback.
    _cachedScreenSize = MediaQuery.of(context).size;
    _cachedSafeAreaPadding = MediaQuery.of(context).padding;

    final lastSelected = context.watch<BoardProvider>().lastSelected;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      body: SafeArea(
        child: Stack(
          children: [
            // Layer 0 — Symbol grid + top bar
            Column(
              children: [
                _TopBar(lastSelectedLabel: lastSelected?.label),
                Expanded(child: AacBoardGrid(key: _gridKey)),
              ],
            ),

            // Layer 1 — Gaze cursor overlay (full screen, pointer-transparent)
            const Positioned.fill(child: GazeCursorOverlay()),

            // Layer 2 — Connection status badge (top-right corner)
            const Positioned(
              right: 12,
              top: 8,
              child: ConnectionStatusBadge(),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String? lastSelectedLabel;

  const _TopBar({this.lastSelectedLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      color: const Color(0xFF16213E),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70),
            onPressed: () => Navigator.pop(context),
          ),
          const Icon(Icons.remove_red_eye_outlined,
              color: Colors.cyanAccent, size: 20),
          const SizedBox(width: 8),
          const Text(
            'Eye Track AAC',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const Spacer(),
          // Last spoken word indicator
          if (lastSelectedLabel != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: Colors.cyanAccent.withValues(alpha: 0.4)),
              ),
              child: Text(
                '▶ $lastSelectedLabel',
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          // Space reserved so the connection status badge overlay never
          // clips the last-selected text.
          const SizedBox(width: 140),
        ],
      ),
    );
  }
}
