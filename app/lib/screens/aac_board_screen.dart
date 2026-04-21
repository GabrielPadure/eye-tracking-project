import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';

import '../models/gaze_point.dart';
import '../providers/board_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/gaze_provider.dart';
import '../widgets/aac_board_grid.dart';
import '../widgets/camera_preview_widget.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/gaze_cursor_overlay.dart';
import '../widgets/symbol_tile.dart';

/// Main AAC communication board screen.
///
/// Layout (landscape iPad):
/// ┌─────────────────────────────────────────────────────────────┐
/// │  [←]  Eye Track AAC          ▶ LastWord  [▶ SIM]  [● Conn]│  ← _TopBar
/// │                                                             │
/// │  ┌──────┐ ┌──────┐                                        │
/// │  │  🖼  │ │  🖼  │                                        │
/// │  │ Yes  │ │  No  │                                        │  ← AacBoardGrid
/// │  └──────┘ └──────┘                                        │    (2 × 2)
/// │  ┌──────┐ ┌──────┐                        [📷 camera]    │
/// │  │ Play │ │ Eat  │                                        │
/// │  └──────┘ └──────┘                                        │
/// │        [gaze dot — transparent overlay]                    │
/// └─────────────────────────────────────────────────────────────┘
///
/// When the simulator is running, gaze coordinates are produced by
/// [GazeSimulatorService] and travel through the same pipeline as the real
/// WebSocket backend.  This screen listens to [GazeProvider] and performs a
/// [RenderBox] hit-test to drive [SymbolTileState.startDwell] /
/// [SymbolTileState.cancelDwell] — the same calls the real backend will make.
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

  // ---------------------------------------------------------------------------
  // Mouse-mode gaze feed
  // ---------------------------------------------------------------------------

  /// Called by the [MouseRegion] overlay when [GazeInputMode.mouse] is active.
  ///
  /// [localPosition] is local to the SafeArea child (i.e. available viewport),
  /// [availableSize] is that same viewport's size — so normalisation is exact.
  void _onMouseHover(Offset localPosition, Size availableSize) {
    if (availableSize == Size.zero) return;
    final point = GazePoint(
      x: (localPosition.dx / availableSize.width).clamp(0.0, 1.0),
      y: (localPosition.dy / availableSize.height).clamp(0.0, 1.0),
      timestamp: DateTime.now(),
    );
    _gazeProvider?.updateGaze(point);
  }

  // ---------------------------------------------------------------------------
  // Gaze hit-test
  // ---------------------------------------------------------------------------

  void _onGazeUpdate() {
    final gaze = _gazeProvider?.gazePoint;
    if (gaze == null) return;

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

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Cache layout data for the hit-test callback.
    _cachedScreenSize = MediaQuery.of(context).size;
    _cachedSafeAreaPadding = MediaQuery.of(context).padding;

    final lastSelected = context.watch<BoardProvider>().lastSelected;
    final isMouseMode =
        context.watch<ConnectionProvider>().inputMode == GazeInputMode.mouse;

    Widget body = Stack(
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

        // Layer 2 — Camera preview (bottom-right corner)
        const Positioned(
          right: 12,
          bottom: 12,
          child: CameraPreviewWidget(),
        ),

        // Layer 3 — Connection status badge (top-right corner)
        const Positioned(
          right: 12,
          top: 8,
          child: ConnectionStatusBadge(),
        ),
      ],
    );

    // Mouse mode: wrap the whole SafeArea content in a LayoutBuilder +
    // MouseRegion so we can convert pointer position → normalised gaze.
    // IMPORTANT: capture `body` (the Stack) in a separate final BEFORE
    // reassigning `body`, otherwise the LayoutBuilder closure would capture
    // the variable by reference and embed itself as its own child (infinite
    // recursion at layout time).
    if (isMouseMode) {
      final stack = body;
      body = LayoutBuilder(
        builder: (context, constraints) {
          final size =
              Size(constraints.maxWidth, constraints.maxHeight);
          return MouseRegion(
            onHover: (event) => _onMouseHover(event.localPosition, size),
            cursor: SystemMouseCursors.none, // hide OS cursor; show gaze dot
            child: stack,
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      body: SafeArea(child: body),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String? lastSelectedLabel;

  const _TopBar({this.lastSelectedLabel});

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionProvider>();

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
          const SizedBox(width: 8),
          // 3-way input-mode selector
          _ModeSelector(conn: conn),
          // Space reserved so the badge overlay never clips text
          const SizedBox(width: 120),
        ],
      ),
    );
  }
}

/// Three-way segmented selector: Mouse | Sim | WebSocket
///
/// Only one mode is active at a time.  Tapping an active mode deactivates it.
class _ModeSelector extends StatelessWidget {
  final ConnectionProvider conn;

  const _ModeSelector({required this.conn});

  @override
  Widget build(BuildContext context) {
    final mode = conn.inputMode;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ModeButton(
          label: 'Mouse',
          icon: Icons.mouse_outlined,
          active: mode == GazeInputMode.mouse,
          activeColor: Colors.greenAccent,
          onTap: () => mode == GazeInputMode.mouse
              ? conn.stopMouseMode()
              : conn.startMouseMode(),
        ),
        const SizedBox(width: 4),
        _ModeButton(
          label: 'Sim',
          icon: Icons.play_circle_outlined,
          active: mode == GazeInputMode.simulator,
          activeColor: Colors.orangeAccent,
          onTap: () => mode == GazeInputMode.simulator
              ? conn.stopSimulation()
              : conn.startSimulation(),
        ),
        const SizedBox(width: 4),
        _ModeButton(
          label: 'WebSocket',
          icon: Icons.wifi_outlined,
          active: mode == GazeInputMode.websocket,
          activeColor: Colors.cyanAccent,
          onTap: () => mode == GazeInputMode.websocket
              ? conn.disconnect()
              : conn.connect(),
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: active ? 'Stop $label mode' : 'Start $label mode',
      child: TextButton.icon(
        style: TextButton.styleFrom(
          backgroundColor:
              active ? activeColor.withValues(alpha: 0.18) : Colors.white10,
          foregroundColor: active ? activeColor : Colors.white54,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: active
                  ? activeColor.withValues(alpha: 0.6)
                  : Colors.white24,
            ),
          ),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        onPressed: onTap,
      ),
    );
  }
}
