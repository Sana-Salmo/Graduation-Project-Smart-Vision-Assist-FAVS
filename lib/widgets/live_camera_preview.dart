import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../core/utils/camera_manager.dart';

/// Renders a live feed from the back camera.
/// Automatically falls back to [placeholder] when:
///   - the device has no camera
///   - camera permission is denied
///   - the platform does not support the camera package (web, desktop)
///   - any initialisation error occurs
///
/// Call sites do not need to import the camera package directly.
class LiveCameraPreview extends StatefulWidget {
  final Widget placeholder;
  const LiveCameraPreview({super.key, required this.placeholder});

  @override
  State<LiveCameraPreview> createState() => _LiveCameraPreviewState();
}

class _LiveCameraPreviewState extends State<LiveCameraPreview> {
  CameraController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ctrl = await CameraManager.initBackCamera();
    if (!mounted) {
      await ctrl?.dispose();
      return;
    }
    setState(() {
      _controller = ctrl;
      _ready = ctrl != null;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready && _controller != null) {
      return CameraPreview(_controller!);
    }
    return widget.placeholder;
  }
}
