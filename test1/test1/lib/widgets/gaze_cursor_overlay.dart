import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/gaze_provider.dart';

/// Full-screen transparent overlay that renders a gaze cursor dot.
///
/// The dot is positioned using normalised (0–1) [GazePoint] coordinates
/// from [GazeProvider], scaled to the actual screen dimensions via
/// [LayoutBuilder]. Place this as the top-most layer in the [Stack] on
/// [AacBoardScreen] so it renders above all other content.
///
/// While the Python backend is not yet connected the dot stays centred.
class GazeCursorOverlay extends StatelessWidget {
  const GazeCursorOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gaze = context.watch<GazeProvider>().gazePoint;
          final px = gaze.x * constraints.maxWidth;
          final py = gaze.y * constraints.maxHeight;

          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 30),
                left: px - 16,
                top: py - 16,
                child: const _GazeDot(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GazeDot extends StatelessWidget {
  const _GazeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.redAccent.withValues(alpha: 0.55),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.redAccent.withValues(alpha: 0.35),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }
}
