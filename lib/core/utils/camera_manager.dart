import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Returns an initialised [CameraController] for the back camera,
/// or null when the camera is unavailable, permission is denied,
/// or the platform is unsupported.  Never throws.
class CameraManager {
  CameraManager._();

  static Future<CameraController?> initBackCamera() async {
    if (kIsWeb) return null;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return null;
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      return controller;
    } catch (_) {
      return null;
    }
  }
}
