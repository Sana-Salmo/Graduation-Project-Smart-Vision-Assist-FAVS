import 'package:flutter_tts/flutter_tts.dart';
import '../../services/settings_service.dart';

/// Singleton TTS helper.  Call [speak] from any screen; [stop] in dispose().
/// Language, rate, and volume are synced from [SettingsService] before speech.
class TtsHelper {
  TtsHelper._();

  static final FlutterTts _tts = FlutterTts();
  static bool _initialized = false;
  static String? _activeLanguage;
  static int _speechToken = 0;
  static bool _speaking = false;
  static Future<void> _speechQueue = Future<void>.value();

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(SettingsService.voiceSpeed);
    await _tts.setVolume(SettingsService.alertVolume);
    await _tts.setPitch(1.0);
  }

  static String _languageForCurrentSettings() {
    return SettingsService.ttsLanguageCode;
  }

  static Future<void> _syncLanguageFromSettings() async {
    final language = _languageForCurrentSettings();
    if (_activeLanguage == language) return;
    await _tts.setLanguage(language);
    _activeLanguage = language;
  }

  static Future<void> _syncVoiceSettings() async {
    await _syncLanguageFromSettings();
    await _tts.setSpeechRate(SettingsService.voiceSpeed);
    await _tts.setVolume(SettingsService.alertVolume);
  }

  /// Strips characters that cause TTS engines to insert unnatural pauses.
  ///
  /// Line breaks in OCR/API output make flutter_tts stop and restart at
  /// every newline.  Replace them with a single space so the engine reads
  /// through naturally; punctuation (.  ,  ?)  still provides proper prosody.
  static String _cleanForTts(String text) {
    return text
        .replaceAll('\r\n', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        // Collapse runs of whitespace (tabs, multiple spaces) to one space.
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        // Remove markdown artefacts that Gemini sometimes emits.
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll(RegExp(r'#+\s*'), '')
        // Normalise multiple consecutive periods to a single one.
        .replaceAll(RegExp(r'\.{2,}'), '.')
        .trim();
  }

  /// Interrupts any current speech and speaks [text].
  static Future<void> speak(String text) => speakInterrupting(text);

  static Future<void> _enqueue(Future<void> Function() action) {
    final previous = _speechQueue;
    final next = previous.catchError((_) {}).then((_) => action());
    _speechQueue = next.catchError((_) {});
    return next;
  }

  /// Stops whatever is currently being spoken, then speaks [text].
  ///
  /// A monotonically increasing token prevents older async TTS calls from
  /// resuming after a newer critical alert has taken over the audio channel.
  static Future<void> speakInterrupting(String text) async {
    final cleaned = _cleanForTts(text);
    if (cleaned.isEmpty) return;
    final token = ++_speechToken;
    await _tts.stop();
    await _enqueue(() async {
      await _ensureInit();
      if (token != _speechToken) return;
      await _tts.stop();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (token != _speechToken) return;
      await _syncVoiceSettings();
      if (token != _speechToken) return;
      _speaking = true;
      try {
        await _tts.speak(cleaned);
      } finally {
        if (token == _speechToken) _speaking = false;
      }
    });
  }

  /// Speaks [text] only if no newer speech request supersedes it.
  ///
  /// This still uses the platform TTS engine normally, but it does not issue an
  /// explicit stop before speaking. Use for lower-priority navigation updates.
  static Future<void> speakPolite(String text) async {
    final cleaned = _cleanForTts(text);
    if (cleaned.isEmpty) return;
    if (_speaking) return;
    final token = ++_speechToken;
    await _enqueue(() async {
      if (_speaking) return;
      await _ensureInit();
      if (token != _speechToken) return;
      await _syncVoiceSettings();
      if (token != _speechToken) return;
      _speaking = true;
      try {
        await _tts.speak(cleaned);
      } finally {
        if (token == _speechToken) _speaking = false;
      }
    });
  }

  /// Silences TTS immediately.  Call in screen dispose().
  static Future<void> stop() async {
    _speechToken++;
    _speaking = false;
    _speechQueue = Future<void>.value();
    await _tts.stop();
  }

  /// Switch language at runtime (e.g. 'ar-SA' for Arabic).
  static Future<void> setLanguage(String langCode) async {
    await _ensureInit();
    if (_activeLanguage == langCode) return;
    await _tts.setLanguage(langCode);
    _activeLanguage = langCode;
  }

  /// Immediately applies the language stored in [SettingsService].
  ///
  /// Use this after the settings screen changes app language, before the next
  /// spoken confirmation. It cancels in-flight speech so the next utterance
  /// cannot inherit the old voice.
  static Future<void> refreshLanguageFromSettings() async {
    _speechToken++;
    _speaking = false;
    _speechQueue = Future<void>.value();
    await _ensureInit();
    await _tts.stop();
    await _syncLanguageFromSettings();
  }

  /// Adjust rate: 0.0 (slowest) – 1.0 (fastest).
  static Future<void> setRate(double rate) async {
    await _ensureInit();
    await _tts.setSpeechRate(rate.clamp(0.0, 1.0));
  }

  /// Adjust TTS volume: 0.0 – 1.0.
  static Future<void> setVolume(double volume) async {
    await _ensureInit();
    await _tts.setVolume(volume.clamp(0.0, 1.0));
  }
}
