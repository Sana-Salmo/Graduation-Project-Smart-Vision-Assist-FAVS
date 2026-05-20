import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/constants/app_colors.dart';
import '../../core/engine/decision_engine.dart';
import '../../core/utils/object_label_localizer.dart';
import '../../core/utils/tts_helper.dart';
import '../../core/utils/voice_enabled_mixin.dart';
import '../../l10n/app_localizations.dart';
import '../../services/navigation_service.dart';
import '../../services/obstacle_detection_service.dart';
import '../../services/voice_command_service.dart';
import '../../widgets/voice_bar.dart';

const Color _navAccent = Color(0xFFE65100);

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with SingleTickerProviderStateMixin, VoiceEnabledMixin {
  final _destController = TextEditingController();
  final _navigationService = NavigationService();
  final _safetyDetectionService = ObstacleDetectionService();

  NavigationRoute? _route;
  CameraController? _cameraController;
  bool _loading = false;
  bool _active = false;
  bool _cameraReady = false;
  bool _safetyProcessing = false;
  bool _disposed = false;
  // _listening tracks the destination-capture mic session (separate from
  // the mixin's voiceListening which handles navigation commands).
  bool _listening = false;
  String _destination = '';
  String? _voiceStatus;
  NavigationRoute? _pendingRoute;
  List<DetectedObstacle> _safetyDetections = const [];
  StreamSubscription<Position>? _positionSubscription;
  int _currentStepIndex = 0;
  bool _arrivalAnnounced = false;
  double? _distanceToDestinationMeters;

  Timer? _routeRefreshTimer;
  DateTime _lastSafetyScanAt = DateTime.fromMillisecondsSinceEpoch(0);

  late final AnimationController _scanController;
  late final Animation<double> _scanAnim;

  // ── VoiceEnabledMixin contract ─────────────────────────────────────────────

  @override
  String get screenWelcome => AppLocalizations.of(context)!.ttsNavWelcome;

  @override
  bool get autoStartVoiceListening => false;

  @override
  bool get speakScreenWelcome => false;

  @override
  Map<List<String>, VoidCallback> get voiceCommands => {
    ['start', 'go', 'navigate', 'ابدأ', 'توجيه', 'انطلق']: () =>
        _startGuidance(),
    ['stop', 'cancel', 'إيقاف', 'توقف']: () => _stopGuidance(),
    ['repeat', 'again', 'كرر', 'أعد']: _repeatInstruction,
    ['back', 'home', 'رجوع', 'الرئيسية']: () => Navigator.pop(context),
  };

  @override
  void initState() {
    super.initState(); // mixin speaks screenWelcome via postFrameCallback
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
      if (!mounted || _active || _listening) return;
      await _askForDestination();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    TtsHelper.stop();
    _destController.dispose();
    _routeRefreshTimer?.cancel();
    _positionSubscription?.cancel();
    _stopSafetyDetection();
    voiceService.stopListening();
    _cameraController?.dispose();
    _safetyDetectionService.dispose();
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty || !mounted || _disposed) return;
      final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted || _disposed) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraReady = true;
      });
    } catch (_) {
      if (mounted && !_disposed) setState(() => _cameraReady = false);
    }
  }

  bool get _arrived =>
      _arrivalAnnounced ||
      (_distanceToDestinationMeters != null &&
          _distanceToDestinationMeters! <= 5);

  NavigationStep? get _activeStep {
    final steps = _route?.steps;
    if (steps == null || steps.isEmpty) return null;
    final index = _currentStepIndex.clamp(0, steps.length - 1).toInt();
    return steps[index];
  }

  String get _currentStep =>
      _activeStep?.instruction ??
      AppLocalizations.of(context)!.calculatingRoute;

  String get _distanceSummary =>
      _activeStep?.distanceLabel ??
      (_distanceToDestinationMeters == null
          ? ''
          : _distanceLabel(_distanceToDestinationMeters!));

  Future<void> _startGuidance({NavigationRoute? preparedRoute}) async {
    final l10n = AppLocalizations.of(context)!;
    final destination = _destController.text.trim();
    if (destination.isEmpty && preparedRoute == null) {
      await TtsHelper.speak(l10n.ttsEnterDestFirst);
      await _askForDestination();
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _voiceStatus = null;
    });

    try {
      final route =
          preparedRoute ??
          await _navigationService.buildRoute(
            destination,
            languageCode: _navigationLanguageCode,
          );
      if (!mounted) return;
      setState(() {
        _route = route;
        _destination = route.destinationName;
        _active = true;
        _loading = false;
        _pendingRoute = null;
        _currentStepIndex = 0;
        _arrivalAnnounced = false;
        _distanceToDestinationMeters = route.totalDistanceMeters;
      });

      _scanController.repeat(reverse: true);
      _scheduleRouteRefresh();
      _startTurnByTurnTracking();
      DecisionEngine.instance.setNavigationActive(true);
      unawaited(_startSafetyDetection());
      await TtsHelper.speak(
        '${l10n.ttsGuidanceStarted(_destination)} ${_routeSummary(route)} ${_spokenStep(_activeStep)}',
      );
      _showInfoSnackBar(_currentStep, icon: Icons.navigation_rounded);
    } on NavigationException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(l10n.errorOccurred);
    }
  }

  Future<void> _refreshRoute() async {
    if (!_active || _destination.isEmpty) return;
    try {
      final route = await _navigationService.buildRoute(
        _destination,
        languageCode: _navigationLanguageCode,
      );
      if (!mounted) return;
      final previousStep = _currentStep;
      setState(() {
        _route = route;
        _currentStepIndex = 0;
        _distanceToDestinationMeters = route.totalDistanceMeters;
      });
      if (route.totalDistanceMeters <= 5) {
        await _announceArrivalAndStop();
        return;
      }
      if (route.steps.isNotEmpty &&
          route.steps.first.instruction != previousStep) {
        final spoken = _spokenStep(route.steps.first);
        await DecisionEngine.instance.onNavigationStep(spoken);
        _showInfoSnackBar(
          route.steps.first.instruction,
          icon: Icons.navigation_rounded,
        );
      }
    } catch (_) {
      // Keep the previous route visible if refresh fails.
    }
  }

  void _scheduleRouteRefresh() {
    _routeRefreshTimer?.cancel();
    _routeRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshRoute(),
    );
  }

  Future<void> _stopGuidance({bool speak = true}) async {
    final stoppedMessage = AppLocalizations.of(context)!.ttsGuidanceStopped;
    _routeRefreshTimer?.cancel();
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _stopSafetyDetection();
    _scanController
      ..stop()
      ..reset();
    DecisionEngine.instance.setNavigationActive(false);
    setState(() {
      _active = false;
      _safetyDetections = const [];
    });
    if (speak) {
      await TtsHelper.speak(stoppedMessage);
    }
  }

  Future<void> _startSafetyDetection() async {
    if (!_cameraReady ||
        _cameraController == null ||
        _cameraController!.value.isStreamingImages) {
      return;
    }

    try {
      await _safetyDetectionService.initialize();
      if (!_active || _disposed || !mounted) return;
      DecisionEngine.instance.setDetectionActive(true);
      await _cameraController!.startImageStream(_onSafetyFrame);
    } catch (e) {
      debugPrint('[NavigationSafety] Could not start pulsed detection: $e');
      DecisionEngine.instance.setDetectionActive(false);
    }
  }

  void _stopSafetyDetection() {
    DecisionEngine.instance.setDetectionActive(false);
    _safetyProcessing = false;
    if (_cameraController?.value.isStreamingImages == true) {
      unawaited(_cameraController!.stopImageStream());
    }
  }

  void _onSafetyFrame(CameraImage frame) {
    if (_disposed || !_active || _safetyProcessing || !mounted) return;

    final now = DateTime.now();
    if (now.difference(_lastSafetyScanAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastSafetyScanAt = now;
    _safetyProcessing = true;

    _safetyDetectionService
        .detectFromCamera(
          frame,
          sensorOrientation:
              _cameraController?.description.sensorOrientation ?? 0,
        )
        .then((detections) {
          if (_disposed || !mounted || !_active) {
            _safetyProcessing = false;
            return;
          }

          final safetyDetections = detections
              .where((detection) => detection.isDanger)
              .take(3)
              .toList(growable: false);
          if (safetyDetections.isNotEmpty) {
            setState(() => _safetyDetections = safetyDetections);
            unawaited(
              DecisionEngine.instance.onObstacleDetected(
                safetyDetections.first,
              ),
            );
          } else if (_safetyDetections.isNotEmpty) {
            setState(() => _safetyDetections = const []);
          }
          _safetyProcessing = false;
        })
        .catchError((error) {
          debugPrint('[NavigationSafety] Frame error: $error');
          _safetyProcessing = false;
        });
  }

  Future<void> _repeatInstruction() async {
    if (_route == null) return;
    await TtsHelper.speak(_spokenStep(_activeStep));
  }

  void _startTurnByTurnTracking() {
    _positionSubscription?.cancel();
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 3,
          ),
        ).listen(
          _handlePositionUpdate,
          onError: (error) =>
              debugPrint('[Navigation] GPS stream error: $error'),
        );
  }

  Future<void> _handlePositionUpdate(Position position) async {
    final route = _route;
    if (!_active || route == null || _arrivalAnnounced || !mounted) return;

    final destinationDistance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      route.destinationLatitude,
      route.destinationLongitude,
    );
    setState(() => _distanceToDestinationMeters = destinationDistance);

    if (destinationDistance <= 5) {
      await _announceArrivalAndStop();
      return;
    }

    final steps = route.steps;
    if (steps.length < 2) return;

    final nextIndex = (_currentStepIndex + 1)
        .clamp(0, steps.length - 1)
        .toInt();
    if (nextIndex <= _currentStepIndex) return;

    final nextStep = steps[nextIndex];
    if (!nextStep.hasManeuverLocation) return;

    final distanceToNextManeuver = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      nextStep.maneuverLatitude!,
      nextStep.maneuverLongitude!,
    );

    if (distanceToNextManeuver <= 12) {
      setState(() => _currentStepIndex = nextIndex);
      final spoken = _spokenStep(
        nextStep,
        distanceOverrideMeters: distanceToNextManeuver,
      );
      await DecisionEngine.instance.onNavigationStep(spoken);
      _showInfoSnackBar(nextStep.instruction, icon: Icons.navigation_rounded);
    }
  }

  Future<void> _announceArrivalAndStop() async {
    if (_arrivalAnnounced || !mounted) return;
    setState(() {
      _arrivalAnnounced = true;
      _distanceToDestinationMeters = 0;
    });
    final message = _arrivalMessage;
    _showInfoSnackBar(message, icon: Icons.flag_rounded);
    await _stopGuidance(speak: false);
    await TtsHelper.speakInterrupting(message);
  }

  Future<void> _toggleVoiceInput() async {
    if (_listening) {
      await voiceService.stopListening();
      if (!mounted) return;
      setState(() {
        _listening = false;
        _voiceStatus = null;
      });
      return;
    }

    try {
      final available = await voiceService.initialize();
      if (!available) {
        _showError('Speech recognition is unavailable.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _listening = true;
        _voiceStatus = _voiceHint;
      });

      await voiceService.startListening(
        localeId: _isArabicUi ? 'ar-SA' : 'en-US',
        onResult: (text, isFinal) async {
          if (!mounted) return;
          setState(() {
            _destController.text = text;
            _destController.selection = TextSelection.collapsed(
              offset: text.length,
            );
            _voiceStatus = text;
          });
          if (isFinal) {
            await voiceService.stopListening();
            if (!mounted) return;
            setState(() => _listening = false);
            await _handleVoiceCommand(text);
          }
        },
      );
    } on VoiceCommandException catch (e) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _voiceStatus = null;
      });
      _showError(e.message);
    }
  }

  Future<void> _askForDestination() async {
    final prompt = _isArabicUi
        ? 'إلى أين تريد الذهاب؟'
        : 'Where do you want to go?';
    await TtsHelper.speak(prompt);
    await _listenForNavigationSpeech(expectConfirmation: false);
  }

  Future<void> _listenForNavigationSpeech({
    required bool expectConfirmation,
  }) async {
    if (_listening) await voiceService.stopListening();
    try {
      final available = await voiceService.initialize();
      if (!available) {
        _showError('Speech recognition is unavailable.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _listening = true;
        _voiceStatus = expectConfirmation
            ? (_isArabicUi ? 'قل نعم أو لا' : 'Say yes or no')
            : _voiceHint;
      });

      await voiceService.startListening(
        localeId: _isArabicUi ? 'ar-SA' : 'en-US',
        onResult: (text, isFinal) async {
          if (!mounted) return;
          setState(() => _voiceStatus = text);
          if (!isFinal || text.trim().isEmpty) return;

          await voiceService.stopListening();
          if (!mounted) return;
          setState(() => _listening = false);

          if (expectConfirmation) {
            await _handleDestinationConfirmation(text);
          } else {
            await _prepareVoiceDestination(text);
          }
        },
      );
    } on VoiceCommandException catch (e) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _voiceStatus = null;
      });
      _showError(e.message);
    }
  }

  Future<void> _prepareVoiceDestination(String spokenText) async {
    final destination = spokenText.trim();
    if (destination.isEmpty) {
      await _askForDestination();
      return;
    }

    _destController.text = destination;
    _destController.selection = TextSelection.collapsed(
      offset: destination.length,
    );
    setState(() => _loading = true);

    try {
      final route = await _navigationService.buildRoute(
        destination,
        languageCode: _navigationLanguageCode,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _pendingRoute = route;
        _destination = route.destinationName;
      });
      final question = _isArabicUi
          ? 'هل تقصد ${route.destinationName}؟'
          : 'Did you mean ${route.destinationName}?';
      await TtsHelper.speak('$question ${_routeSummary(route)}');
      if (mounted) {
        await _listenForNavigationSpeech(expectConfirmation: true);
      }
    } on NavigationException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(e.message);
      await _askForDestination();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(AppLocalizations.of(context)!.errorOccurred);
      await _askForDestination();
    }
  }

  Future<void> _handleDestinationConfirmation(String spokenText) async {
    final normalized = spokenText.trim().toLowerCase();
    final yesWords = _isArabicUi
        ? const ['نعم', 'ايه', 'أجل', 'تمام', 'صحيح']
        : const ['yes', 'yeah', 'correct', 'right', 'start', 'ok', 'okay'];
    final noWords = _isArabicUi
        ? const ['لا', 'كلا', 'خطأ', 'غير']
        : const ['no', 'wrong', 'cancel', 'different'];

    if (yesWords.any(normalized.contains) && _pendingRoute != null) {
      await TtsHelper.speak(
        _isArabicUi ? 'سأبدأ التوجيه الآن.' : 'Starting guidance now.',
      );
      await _startGuidance(preparedRoute: _pendingRoute);
      return;
    }

    if (noWords.any(normalized.contains)) {
      setState(() {
        _pendingRoute = null;
      });
      await _askForDestination();
      return;
    }

    await TtsHelper.speak(
      _isArabicUi
          ? 'لم أفهم. هل تقصد هذه الوجهة؟ قل نعم أو لا.'
          : 'I did not understand. Did you mean this destination? Say yes or no.',
    );
    await _listenForNavigationSpeech(expectConfirmation: true);
  }

  Future<void> _handleVoiceCommand(String spokenText) async {
    final normalized = spokenText.trim().toLowerCase();
    if (normalized.isEmpty) return;

    final isArabic = _isArabicUi;
    final startWords = isArabic
        ? const ['ابدأ', 'ابدا', 'تشغيل', 'توجيه']
        : const ['start', 'go', 'navigate'];
    final stopWords = isArabic
        ? const ['ايقاف', 'إيقاف', 'قف', 'توقف']
        : const ['stop', 'cancel'];
    final repeatWords = isArabic
        ? const ['كرر', 'اعادة', 'إعادة']
        : const ['repeat', 'again'];

    if (startWords.any(normalized.contains)) {
      await _startGuidance();
      return;
    }
    if (stopWords.any(normalized.contains)) {
      await _stopGuidance();
      return;
    }
    if (repeatWords.any(normalized.contains)) {
      await _repeatInstruction();
    }
  }

  void _showInfoSnackBar(String message, {required IconData icon}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: _navAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
    TtsHelper.speak(message);
  }

  String get _voiceHint => _isArabicUi
      ? 'تحدث بالوجهة أو قل ابدأ التوجيه'
      : 'Speak a destination or say start guidance';

  bool get _isArabicUi => Localizations.localeOf(context).languageCode == 'ar';

  String get _navigationLanguageCode => _isArabicUi ? 'ar' : 'en';

  String get _arrivalMessage => _isArabicUi
      ? '\u0644\u0642\u062f \u0648\u0635\u0644\u062a \u0625\u0644\u0649 \u0648\u062c\u0647\u062a\u0643 \u0628\u0646\u062c\u0627\u062d.'
      : 'You have arrived at your destination successfully.';

  String _spokenStep(NavigationStep? step, {double? distanceOverrideMeters}) {
    if (step == null) return '';
    final instruction = step.instruction.trim();
    if (instruction.isEmpty) return '';

    final lower = instruction.toLowerCase();
    final isDepart =
        lower.startsWith('start') ||
        instruction.startsWith('\u0627\u0628\u062f\u0623');
    final isArrive =
        lower.contains('arrived') ||
        instruction.contains('\u0648\u0635\u0644\u062a');
    final distanceMeters = distanceOverrideMeters ?? step.distanceMeters;
    if (isDepart || isArrive || distanceMeters <= 0) {
      return instruction;
    }

    final distance = _distanceLabel(distanceMeters);
    return _isArabicUi
        ? '\u0628\u0639\u062f $distance\u060c $instruction'
        : 'In $distance, $instruction';
  }

  String _distanceLabel(double meters) {
    if (meters >= 1000) {
      final km = (meters / 1000).toStringAsFixed(1);
      return _isArabicUi
          ? '$km \u0643\u064a\u0644\u0648\u0645\u062a\u0631'
          : '$km kilometers';
    }
    final rounded = meters.round();
    return _isArabicUi ? '$rounded \u0645\u062a\u0631' : '$rounded meters';
  }

  String _routeSummary(NavigationRoute route) {
    final minutes = (route.totalDurationSeconds / 60).ceil();
    final isArabic = _isArabicUi;
    final distance = route.totalDistanceMeters >= 1000
        ? '${(route.totalDistanceMeters / 1000).toStringAsFixed(1)} ${isArabic ? 'كيلومتر' : 'kilometers'}'
        : '${route.totalDistanceMeters.round()} ${isArabic ? 'متر' : 'meters'}';
    if (isArabic) {
      return 'المسار مشياً حوالي $distance، وسيستغرق تقريباً $minutes دقيقة.';
    }
    return 'The walking route is about $distance and should take about $minutes minutes.';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final stepCount = _route?.steps.length ?? 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: VoiceBar(voice: this),
      appBar: AppBar(
        title: Text(
          l10n.navigation,
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
                l10n.navSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              _DestinationInput(
                controller: _destController,
                enabled: !_loading,
                listening: _listening,
                onVoiceTap: _toggleVoiceInput,
              ),
              if (_voiceStatus != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    _voiceStatus!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: _navAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _GuidanceButton(
                loading: _loading,
                active: _active,
                arrived: _arrived,
                onStart: () => _startGuidance(),
                onStop: () => _stopGuidance(),
              ),
              const SizedBox(height: 20),
              _CameraPreviewArea(
                active: _active,
                arrived: _arrived,
                scanAnim: _scanAnim,
                currentStep: _active && _route != null ? _currentStep : null,
                cameraController: _cameraController,
                safetyDetections: _safetyDetections,
              ),
              const SizedBox(height: 20),
              if (_route != null)
                _InstructionCard(
                  destination: _destination,
                  step: _currentStep,
                  stepNumber: _currentStepIndex + 1,
                  totalSteps: stepCount,
                  steps: _route!.steps,
                  currentStepIndex: _currentStepIndex,
                  active: _active,
                  arrived: _arrived,
                  distanceLabel: _distanceSummary,
                ),
              const SizedBox(height: 16),
              _HazardCard(
                active: _active,
                arrived: _arrived,
                detections: _safetyDetections,
              ),
              const SizedBox(height: 16),
              _RepeatButton(
                enabled: _active && _route != null,
                onPressed: _repeatInstruction,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DestinationInput extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool listening;
  final VoidCallback onVoiceTap;

  const _DestinationInput({
    required this.controller,
    required this.enabled,
    required this.listening,
    required this.onVoiceTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.streetAddress,
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 16, color: AppColors.textDark),
      decoration: InputDecoration(
        hintText: AppLocalizations.of(context)!.destinationHint,
        hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 15),
        prefixIcon: const Icon(Icons.place_rounded, color: _navAccent),
        suffixIcon: IconButton(
          onPressed: enabled ? onVoiceTap : null,
          icon: Icon(
            listening ? Icons.mic : Icons.mic_none_rounded,
            color: listening ? AppColors.error : _navAccent,
          ),
          tooltip: 'Voice input',
        ),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _navAccent, width: 1.8),
        ),
      ),
    );
  }
}

class _GuidanceButton extends StatelessWidget {
  final bool loading;
  final bool active;
  final bool arrived;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _GuidanceButton({
    required this.loading,
    required this.active,
    required this.arrived,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = loading
        ? l10n.calculatingRoute
        : arrived
        ? l10n.startNewRoute
        : active
        ? l10n.stopGuidance
        : l10n.startGuidance;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: loading ? null : (active ? onStop : onStart),
        icon: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(
                arrived
                    ? Icons.flag_rounded
                    : active
                    ? Icons.stop_circle_rounded
                    : Icons.navigation_rounded,
              ),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: arrived
              ? const Color(0xFF2E7D32)
              : active
              ? const Color(0xFF424242)
              : _navAccent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class _CameraPreviewArea extends StatelessWidget {
  final bool active;
  final bool arrived;
  final Animation<double> scanAnim;
  final String? currentStep;
  final CameraController? cameraController;
  final List<DetectedObstacle> safetyDetections;

  const _CameraPreviewArea({
    required this.active,
    required this.arrived,
    required this.scanAnim,
    required this.currentStep,
    required this.cameraController,
    required this.safetyDetections,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: arrived
              ? const Color(0xFF2E7D32)
              : active
              ? _navAccent
              : Colors.transparent,
          width: 3,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: double.infinity,
          height: MediaQuery.sizeOf(context).height * 0.46,
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
              if (active && !arrived)
                AnimatedBuilder(
                  animation: scanAnim,
                  builder: (_, _) => Positioned(
                    top:
                        scanAnim.value *
                        (MediaQuery.sizeOf(context).height * 0.46 - 20),
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 2,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            _navAccent,
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (currentStep != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      currentStep!,
                      style: const TextStyle(color: Colors.white, height: 1.4),
                    ),
                  ),
                ),
              if (safetyDetections.isNotEmpty)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _SafetyOverlay(detection: safetyDetections.first),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructionCard extends StatelessWidget {
  final String destination;
  final String step;
  final int stepNumber;
  final int totalSteps;
  final List<NavigationStep> steps;
  final int currentStepIndex;
  final bool active;
  final bool arrived;
  final String distanceLabel;

  const _InstructionCard({
    required this.destination,
    required this.step,
    required this.stepNumber,
    required this.totalSteps,
    required this.steps,
    required this.currentStepIndex,
    required this.active,
    required this.arrived,
    required this.distanceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
              const Icon(Icons.navigation_rounded, color: _navAccent, size: 18),
              const SizedBox(width: 8),
              Text(
                l10n.currentInstruction,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: _navAccent,
                ),
              ),
              const Spacer(),
              Text(
                totalSteps > 0
                    ? l10n.stepOf(stepNumber, totalSteps)
                    : distanceLabel,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          Text(
            destination,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            step,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.textDark,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            arrived ? l10n.arrivedLabel : distanceLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: arrived ? const Color(0xFF2E7D32) : _navAccent,
            ),
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 14),
            _RoutePlanList(
              steps: steps,
              currentStepIndex: currentStepIndex,
              arabic: Localizations.localeOf(context).languageCode == 'ar',
            ),
          ],
          if (!active && !arrived) const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _RoutePlanList extends StatelessWidget {
  final List<NavigationStep> steps;
  final int currentStepIndex;
  final bool arabic;

  const _RoutePlanList({
    required this.steps,
    required this.currentStepIndex,
    required this.arabic,
  });

  @override
  Widget build(BuildContext context) {
    final title = arabic
        ? '\u062e\u0637\u0629 \u0627\u0644\u0637\u0631\u064a\u0642'
        : 'Route plan';
    final currentLabel = arabic ? '\u0627\u0644\u0622\u0646' : 'Now';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.list_alt_rounded, color: _navAccent, size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: _navAccent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 190,
          child: Scrollbar(
            child: ListView.separated(
              primary: false,
              itemCount: steps.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final step = steps[index];
                final isCurrent = index == currentStepIndex;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? _navAccent.withValues(alpha: 0.10)
                        : const Color(0xFFF7F7F7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isCurrent ? _navAccent : const Color(0xFFE6E6E6),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 13,
                        backgroundColor: isCurrent
                            ? _navAccent
                            : const Color(0xFFE0E0E0),
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: isCurrent
                                ? Colors.white
                                : AppColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              step.instruction,
                              style: TextStyle(
                                color: AppColors.textDark,
                                fontSize: 13,
                                height: 1.35,
                                fontWeight: isCurrent
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isCurrent
                                  ? '$currentLabel - ${step.distanceLabel}'
                                  : step.distanceLabel,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _SafetyOverlay extends StatelessWidget {
  final DetectedObstacle detection;

  const _SafetyOverlay({required this.detection});

  @override
  Widget build(BuildContext context) {
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${ObjectLabelLocalizer.object(detection.label, arabic: arabic)} - '
        '${ObjectLabelLocalizer.direction(detection.direction, arabic: arabic)} - '
        '${detection.distance}',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HazardCard extends StatelessWidget {
  final bool active;
  final bool arrived;
  final List<DetectedObstacle> detections;

  const _HazardCard({
    required this.active,
    required this.arrived,
    required this.detections,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final label = arrived
        ? l10n.noFurtherHazards
        : active
        ? l10n.scanningEnvironment
        : l10n.noHazardsYet;

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
                color: AppColors.error,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.hazardAlerts,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: AppColors.error,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          if (detections.isEmpty)
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            ...detections.map(
              (detection) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${ObjectLabelLocalizer.object(detection.label, arabic: arabic)} - '
                  '${ObjectLabelLocalizer.direction(detection.direction, arabic: arabic)} - '
                  '${detection.distance}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (!active)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.noHazardsHint,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RepeatButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onPressed;

  const _RepeatButton({required this.enabled, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: const Icon(Icons.record_voice_over_rounded, size: 22),
        label: Text(l10n.voiceGuidance),
        style: OutlinedButton.styleFrom(
          foregroundColor: _navAccent,
          padding: const EdgeInsets.symmetric(vertical: 14),
          side: BorderSide(
            color: enabled ? _navAccent : const Color(0xFFDDDDDD),
            width: 1.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}
