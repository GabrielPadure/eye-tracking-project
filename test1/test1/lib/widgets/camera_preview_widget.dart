import 'package:flutter/material.dart';

/// Small camera preview widget shown in the bottom-right corner of the
/// AAC board screen, providing visual feedback that the eye-tracking
/// camera is active.
///
/// -- INTEGRATION NOTES --
/// Replace the placeholder Container below with a real [CameraPreview] widget:
///
///   1. Add a [CameraController] field, initialise it in [initState] using the
///      front-facing camera, and await [controller.initialize()].
///   2. Wrap [CameraPreview(controller)] with [AspectRatio] to avoid distortion.
///   3. Dispose the controller in [dispose].
///   4. Request the NSCameraUsageDescription (iOS) and camera
///      permission (Android) — already added to Info.plist.
class CameraPreviewWidget extends StatelessWidget {
  const CameraPreviewWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      height: 120,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      // TODO: Replace with real CameraPreview once CameraController is wired up.
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_outlined, color: Colors.white54, size: 32),
          SizedBox(height: 4),
          Text(
            'Camera\nPlaceholder',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
