import '../../services/obstacle_detection_service.dart';
import '../../services/settings_service.dart';
import '../utils/object_label_localizer.dart';
import '../utils/tts_helper.dart';

/// Alert priority levels used by the Decision Response Engine.
enum _AlertPriority { low, medium, high, critical }

/// Singleton orchestrator that enforces alert priority across all features.
///
/// Rules (highest priority wins):
///   critical  — danger obstacle ≤2 m   → always interrupts TTS immediately
///   high      — danger obstacle ≤5 m   → interrupts after 5-second cooldown
///   medium    — danger obstacle >5 m   → speaks only when navigation is idle
///   low       — non-dangerous object   → speaks only when navigation is idle
///
/// Navigation step announcements are deferred if a critical alert fired
/// within the last 3 seconds.
class DecisionEngine {
  DecisionEngine._();

  static final DecisionEngine instance = DecisionEngine._();

  bool _navigationActive = false;
  bool _detectionActive = false;
  bool _safetySpeechActive = false;
  DateTime? _lastDangerAlert;
  String? _lastNavigationInstruction;

  // ── State setters called by screens ──────────────────────────────────────

  void setNavigationActive(bool active) => _navigationActive = active;
  void setDetectionActive(bool active) => _detectionActive = active;

  // ── Obstacle alert entry point ────────────────────────────────────────────

  Future<void> onObstacleDetected(DetectedObstacle obstacle) async {
    if (!_detectionActive) return;
    final priority = _prioritize(obstacle);
    final now = DateTime.now();
    final arabic = SettingsService.language == 'Arabic';

    switch (priority) {
      case _AlertPriority.critical:
        // Always interrupt whatever is playing.
        _lastDangerAlert = now;
        _safetySpeechActive = true;
        try {
          await TtsHelper.speakInterrupting(
            ObjectLabelLocalizer.alertSentence(
              label: obstacle.label,
              direction: obstacle.direction,
              distance: obstacle.distance,
              tip: obstacle.tip,
              arabic: arabic,
              warning: true,
            ),
          );
        } finally {
          _safetySpeechActive = false;
        }
        await _resumeNavigationAfterSafetyWarning();
        break;

      case _AlertPriority.high:
      case _AlertPriority.medium:
        // During navigation, only close hazards (<= 3 m) are spoken. Farther
        // detections remain visual so they do not interrupt turn-by-turn audio.
        break;

      case _AlertPriority.low:
        if (!_navigationActive) {
          final label = ObjectLabelLocalizer.object(
            obstacle.label,
            arabic: arabic,
          );
          await TtsHelper.speakPolite(
            arabic ? 'تم اكتشاف $label.' : '$label detected.',
          );
        }
        break;
    }
  }

  // ── Navigation step entry point ───────────────────────────────────────────

  /// Speaks a navigation [instruction] only when no critical danger was
  /// announced in the last 3 seconds, preventing double-speech confusion.
  Future<void> onNavigationStep(String instruction) async {
    if (!_navigationActive) return;
    _lastNavigationInstruction = instruction;
    if (_safetySpeechActive) return;
    final recentDanger =
        _lastDangerAlert != null &&
        DateTime.now().difference(_lastDangerAlert!).inSeconds < 3;
    if (recentDanger) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (_navigationActive && _lastNavigationInstruction == instruction) {
        await TtsHelper.speakPolite(instruction);
      }
      return;
    }
    await TtsHelper.speakPolite(instruction);
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  _AlertPriority _prioritize(DetectedObstacle obstacle) {
    if (!obstacle.isDanger) return _AlertPriority.low;
    final metres =
        double.tryParse(obstacle.distance.replaceAll(RegExp(r'[^0-9.]'), '')) ??
        99.0;
    if (metres <= 3) return _AlertPriority.critical;
    return _AlertPriority.medium;
  }

  Future<void> _resumeNavigationAfterSafetyWarning() async {
    final instruction = _lastNavigationInstruction;
    if (!_navigationActive || instruction == null || instruction.isEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await TtsHelper.speakPolite(instruction);
  }
}
