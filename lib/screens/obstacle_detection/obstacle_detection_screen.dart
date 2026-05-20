import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/engine/decision_engine.dart';
import '../../core/utils/object_label_localizer.dart';
import '../../core/utils/tts_helper.dart';
import '../../core/utils/voice_enabled_mixin.dart';
import '../../l10n/app_localizations.dart';
import '../../services/obstacle_detection_service.dart';
import '../../widgets/voice_bar.dart';

class ObstacleDetectionScreen extends StatefulWidget {
  const ObstacleDetectionScreen({super.key});

  @override
  State<ObstacleDetectionScreen> createState() =>
      _ObstacleDetectionScreenState();
}

class _ObstacleDetectionScreenState extends State<ObstacleDetectionScreen>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        VoiceEnabledMixin {
  final _service = ObstacleDetectionService();

  // Camera — owned by this screen so we can start/stop the image stream.
  CameraController? _cameraController;
  bool _cameraReady = false;
  // True while an inference call is in flight; prevents frame pile-up.
  bool _processing = false;
  // True while startDetection is initializing model/TTS/stream.
  bool _startingDetection = false;
  // Set to true at the very beginning of dispose() to gate _onFrame.
  bool _disposed = false;

  // Detection state
  bool _detecting = false;
  String? _statusMessage;
  final List<DetectedObstacle> _detected = [];
  List<DetectedObstacle> _currentFrameDetections = const [];

  // Demo-mode fallback (used when camera is unavailable, e.g. emulator).
  Timer? _demoTimer;
  DateTime _lastEmptyStatusAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _demoIndex = 0;

  late final AnimationController _scanController;
  late final Animation<double> _scanAnim;

  // ── VoiceEnabledMixin contract ─────────────────────────────────────────────

  @override
  String get screenWelcome => AppLocalizations.of(context)!.ttsDetectionWelcome;

  @override
  bool get autoStartVoiceListening => false;

  @override
  bool get speakScreenWelcome => false;

  @override
  bool get restartListeningAfterUnknownCommand => false;

  @override
  Map<List<String>, VoidCallback> get voiceCommands => {
    ['start', 'detect', 'scan', 'ابدأ', 'كشف', 'مسح']: () {
      if (!_detecting) _startDetection();
    },
    ['stop', 'إيقاف', 'قف']: () {
      if (_detecting) _stopDetection();
    },
    ['repeat', 'last', 'تكرار', 'أعد']: _repeatLastAlert,
    ['back', 'home', 'رجوع', 'الرئيسية']: () => Navigator.pop(context),
  };

  @override
  void initState() {
    super
        .initState(); // mixin initState speaks screenWelcome via postFrameCallback
    WidgetsBinding.instance.addObserver(this);
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _scanAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _scanController, curve: Curves.easeInOut),
    );
    _initCamera();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await TtsHelper.stop();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || _detecting) return;
      await TtsHelper.speak(
        _isArabicUi
            ? 'سأبدأ كشف العوائق الآن. وجه الكاميرا للأمام.'
            : 'I will start obstacle detection now. Point the camera forward.',
      );
      if (mounted && !_detecting) await _startDetection();
    });
  }

  bool get _isArabicUi => Localizations.localeOf(context).languageCode == 'ar';

  // Pause detection automatically when app is backgrounded or screen covered.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_detecting) _stopDetection();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty || !mounted || _disposed) return;
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // yuv420 is required to receive raw frames via startImageStream.
      // ResolutionPreset.low (~320×240) halves per-frame memory vs medium.
      final ctrl = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await ctrl.initialize();
      if (!mounted || _disposed) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _cameraController = ctrl;
        _cameraReady = true;
      });
    } catch (_) {
      if (mounted && !_disposed) setState(() => _cameraReady = false);
    }
  }

  @override
  void dispose() {
    // Gate _onFrame FIRST so no new inference calls are started.
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _demoTimer?.cancel();
    // Stop stream before closing camera hardware.
    _stopImageStream();
    // Dispose camera hardware before closing the TFLite interpreter,
    // so no in-flight frame can call _interpreter!.run() after it closes.
    _cameraController?.dispose();
    _scanController.dispose();
    DecisionEngine.instance.setDetectionActive(false);
    TtsHelper.stop();
    _service.dispose();
    super.dispose();
  }

  void _stopImageStream() {
    if (_cameraController?.value.isStreamingImages == true) {
      _cameraController!.stopImageStream();
    }
  }

  bool get _dangerActive =>
      _detecting && _detected.isNotEmpty && _detected.first.isDanger;

  // ── Detection lifecycle ───────────────────────────────────────────────────

  Future<void> _startDetection() async {
    if (_startingDetection || _detecting) return;
    _startingDetection = true;
    final l10n = AppLocalizations.of(context)!;
    await stopVoiceListening();
    setState(() {
      _detecting = true;
      _statusMessage = null;
      _detected.clear();
      _currentFrameDetections = const [];
      _demoIndex = 0;
    });

    DecisionEngine.instance.setDetectionActive(true);

    try {
      await _service.initialize();
      if (!mounted) return;
      setState(() => _statusMessage = l10n.scanningLabel);
    } on ObstacleDetectionException catch (e) {
      if (!mounted) return;
      debugPrint('[ObstacleDetection] Model error: ${e.message}');
      final message = _localizedDetectionError();
      _scanController.stop();
      DecisionEngine.instance.setDetectionActive(false);
      setState(() {
        _detecting = false;
        _statusMessage = message;
      });
      await TtsHelper.speak(message);
      _startingDetection = false;
      return;
    }

    _scanController.repeat(reverse: true);
    await TtsHelper.speak(l10n.ttsDetectionStarted);
    if (!mounted) {
      _startingDetection = false;
      return;
    }

    if (_cameraReady && _cameraController != null) {
      // Real inference via live camera stream.
      if (_cameraController!.value.isStreamingImages) {
        _startingDetection = false;
        return;
      }
      try {
        await _cameraController!.startImageStream(_onFrame);
      } on CameraException catch (e) {
        if (!mounted) {
          _startingDetection = false;
          return;
        }
        setState(() {
          _detecting = false;
          _statusMessage = _localizedDetectionError();
        });
        DecisionEngine.instance.setDetectionActive(false);
        await TtsHelper.speak(_statusMessage!);
      }
    } else {
      // Emulator / no camera — cycle through demo obstacles.
      _startDemoMode();
    }
    _startingDetection = false;
  }

  /// Camera image stream callback. Skips frames while the previous inference
  /// is still running to avoid a backlog of in-flight isolate calls.
  void _onFrame(CameraImage frame) {
    if (_disposed || _processing || !_detecting || !mounted) return;
    _processing = true;

    _service
            .detectFromCamera(
              frame,
              sensorOrientation:
                  _cameraController?.description.sensorOrientation ?? 0,
            )
        .then((obstacles) {
          if (_disposed || !mounted || !_detecting) {
            _processing = false;
            return;
          }
          if (obstacles.isNotEmpty) {
            final newest = obstacles.first;
            setState(() {
              _currentFrameDetections = obstacles;
              _detected.insert(0, newest);
            });
            _announceObstacle(newest);
          } else {
            if (_currentFrameDetections.isNotEmpty) {
              setState(() => _currentFrameDetections = const []);
            }
            _updateEmptyDetectionStatus();
          }
          _processing = false;
        })
        .catchError((error) {
          debugPrint('[ObstacleDetection] Frame error: $error');
          if (mounted && !_disposed) {
            final message = error is ObstacleDetectionException
                ? error.message
                : 'Detection error: $error';
            setState(() => _statusMessage = message);
          }
          _processing = false;
        });
  }

  void _updateEmptyDetectionStatus() {
    final now = DateTime.now();
    if (now.difference(_lastEmptyStatusAt).inSeconds < 2) return;
    _lastEmptyStatusAt = now;
    final score = _service.lastBestScore;
    final label = _service.lastBestLabel;
    setState(() {
      _statusMessage =
          'Scanning. Strongest signal: $label ${(score * 100).toStringAsFixed(0)}%.';
    });
  }

  String _localizedDetectionError() {
    return _isArabicUi
        ? 'تعذر تشغيل كشف العوائق. يرجى المحاولة مرة أخرى.'
        : 'Unable to start obstacle detection. Please try again.';
  }

  void _startDemoMode() {
    final demoObstacles = _service.demoObstacles();
    _demoTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || !_detecting) {
        timer.cancel();
        return;
      }
      if (_demoIndex >= demoObstacles.length) _demoIndex = 0;
      final obstacle = demoObstacles[_demoIndex++];
      setState(() => _detected.insert(0, obstacle));
      _announceObstacle(obstacle);
    });
  }

  Future<void> _stopDetection() async {
    _demoTimer?.cancel();
    _stopImageStream();
    _processing = false;
    _startingDetection = false;
    _scanController
      ..stop()
      ..reset();
    DecisionEngine.instance.setDetectionActive(false);
    setState(() {
      _detecting = false;
      _currentFrameDetections = const [];
    });
    await TtsHelper.speak(AppLocalizations.of(context)!.ttsDetectionStopped);
    await restartVoiceListeningSoon();
  }

  Future<void> _repeatLastAlert() async {
    if (_detected.isEmpty) return;
    final o = _detected.first;
    await TtsHelper.speak(
      ObjectLabelLocalizer.alertSentence(
        label: o.label,
        direction: o.direction,
        distance: o.distance,
        tip: o.tip,
        arabic: _isArabicUi,
      ),
    );
  }

  /// Routes every obstacle alert through the Decision Engine so priority
  /// rules (critical / high / medium / low) are enforced consistently.
  void _announceObstacle(DetectedObstacle obstacle) {
    DecisionEngine.instance.onObstacleDetected(obstacle);
    final arabic = _isArabicUi;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${ObjectLabelLocalizer.object(obstacle.label, arabic: arabic)} - '
          '${ObjectLabelLocalizer.direction(obstacle.direction, arabic: arabic)} - '
          '${obstacle.distance}',
        ),
        backgroundColor: obstacle.isDanger
            ? AppColors.error
            : const Color(0xFFE65100),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: VoiceBar(voice: this),
      appBar: AppBar(
        title: Text(
          l10n.obstacleDetection,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            children: [
              Text(
                l10n.obstacleSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              _CameraPreviewArea(
                detecting: _detecting,
                dangerActive: _dangerActive,
                scanAnim: _scanAnim,
                latestObstacle: _detected.isNotEmpty ? _detected.first : null,
                detections: _currentFrameDetections,
                cameraController: _cameraController,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _detecting ? _stopDetection : _startDetection,
                  icon: Icon(
                    _detecting
                        ? Icons.stop_circle_rounded
                        : Icons.sensors_rounded,
                  ),
                  label: Text(
                    _detecting ? l10n.stopDetection : l10n.startDetection,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _detecting
                        ? const Color(0xFF424242)
                        : AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE0E0E0)),
                  ),
                  child: Text(
                    _statusMessage!,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _AlertsCard(detected: _detected, detecting: _detecting),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _detected.isEmpty ? null : _repeatLastAlert,
                  icon: const Icon(Icons.volume_up_rounded),
                  label: Text(l10n.speakLastAlert),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                      color: _detected.isEmpty
                          ? const Color(0xFFDDDDDD)
                          : AppColors.error,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Private widgets ───────────────────────────────────────────────────────────

class _CameraPreviewArea extends StatelessWidget {
  final bool detecting;
  final bool dangerActive;
  final Animation<double> scanAnim;
  final DetectedObstacle? latestObstacle;
  final List<DetectedObstacle> detections;
  final CameraController? cameraController;

  const _CameraPreviewArea({
    required this.detecting,
    required this.dangerActive,
    required this.scanAnim,
    required this.latestObstacle,
    required this.detections,
    required this.cameraController,
  });

  @override
  Widget build(BuildContext context) {
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: dangerActive
              ? AppColors.error
              : detecting
              ? const Color(0xFF00E5FF)
              : Colors.transparent,
          width: 3,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: double.infinity,
          height: MediaQuery.sizeOf(context).height * 0.52,
          child: Stack(
            children: [
              Positioned.fill(
                child:
                    cameraController != null &&
                        cameraController!.value.isInitialized
                    ? CameraPreview(cameraController!)
                    : Container(
                        color: const Color(0xFF1A1A2E),
                        alignment: Alignment.center,
                        child: Text(
                          AppLocalizations.of(context)!.cameraNotAvailable,
                          style: const TextStyle(color: Color(0xFFB0B0D0)),
                        ),
                      ),
              ),
              if (detecting)
                AnimatedBuilder(
                  animation: scanAnim,
                  builder: (_, _) => Positioned(
                    top:
                        scanAnim.value *
                        (MediaQuery.sizeOf(context).height * 0.52 - 20),
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            dangerActive
                                ? AppColors.error
                                : const Color(0xFF00E5FF),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (detections.any((d) => d.hasBox))
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _DetectionBoxPainter(
                        detections
                            .where((d) => d.hasBox)
                            .take(5)
                            .toList(growable: false),
                        arabic: arabic,
                      ),
                    ),
                  ),
                ),
              if (latestObstacle != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color:
                          (latestObstacle!.isDanger
                                  ? AppColors.error
                                  : const Color(0xFFE65100))
                              .withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${ObjectLabelLocalizer.object(latestObstacle!.label, arabic: arabic)} - '
                      '${ObjectLabelLocalizer.direction(latestObstacle!.direction, arabic: arabic)} - '
                      '${latestObstacle!.distance}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertsCard extends StatelessWidget {
  final List<DetectedObstacle> detected;
  final bool detecting;

  const _AlertsCard({required this.detected, required this.detecting});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.detectionResult,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          if (detected.isEmpty)
            Text(
              detecting ? l10n.scanningLabel : l10n.noObstaclesYet,
              style: const TextStyle(color: AppColors.textMuted),
            )
          else
            ...detected
                .take(5)
                .map(
                  (o) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      '${ObjectLabelLocalizer.object(o.label, arabic: arabic)}'
                      '${o.confidence == null ? '' : ' ${(o.confidence! * 100).toStringAsFixed(0)}%'} - '
                      '${ObjectLabelLocalizer.direction(o.direction, arabic: arabic)} - '
                      '${o.distance} - ${ObjectLabelLocalizer.tip(o.tip, arabic: arabic)}',
                      style: const TextStyle(
                        color: AppColors.textDark,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _DetectionBoxPainter extends CustomPainter {
  final List<DetectedObstacle> detections;
  final bool arabic;

  const _DetectionBoxPainter(this.detections, {required this.arabic});

  @override
  void paint(Canvas canvas, Size size) {
    for (final detection in detections) {
      final left =
          detection.left!.clamp(0.0, 1.0).toDouble() * size.width;
      final top = detection.top!.clamp(0.0, 1.0).toDouble() * size.height;
      final right =
          detection.right!.clamp(0.0, 1.0).toDouble() * size.width;
      final bottom =
          detection.bottom!.clamp(0.0, 1.0).toDouble() * size.height;
      final rect = Rect.fromLTRB(left, top, right, bottom);
      final color = detection.isDanger
          ? AppColors.error
          : const Color(0xFF00E5FF);

      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawRect(rect, boxPaint);

      final label =
          '${ObjectLabelLocalizer.object(detection.label, arabic: arabic)}'
          '${detection.confidence == null ? '' : ' ${(detection.confidence! * 100).toStringAsFixed(0)}%'}';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width - 16);

      final labelWidth = textPainter.width + 12;
      final labelHeight = textPainter.height + 8;
      final labelLeft = left
          .clamp(0.0, size.width - labelWidth)
          .toDouble();
      final labelTop = (top - labelHeight)
          .clamp(0.0, size.height - labelHeight)
          .toDouble();
      final labelRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight),
        const Radius.circular(6),
      );
      canvas.drawRRect(labelRect, Paint()..color = color.withValues(alpha: 0.9));
      textPainter.paint(canvas, Offset(labelLeft + 6, labelTop + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter oldDelegate) =>
      oldDelegate.detections != detections || oldDelegate.arabic != arabic;
}
