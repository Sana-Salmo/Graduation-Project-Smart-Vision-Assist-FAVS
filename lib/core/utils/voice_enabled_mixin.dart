import 'package:flutter/material.dart';

import '../../services/settings_service.dart';
import '../../services/voice_command_service.dart';
import 'tts_helper.dart';

/// Adds voice-command behavior to a screen.
///
/// Screens can opt out of automatic microphone startup when they run heavy
/// camera/ML workloads by overriding [autoStartVoiceListening].
mixin VoiceEnabledMixin<T extends StatefulWidget> on State<T> {
  final VoiceCommandService voiceService = VoiceCommandService();
  bool voiceListening = false;
  String? voicePartialResult;
  bool _autoListeningStarted = false;

  String get screenWelcome;
  Map<List<String>, VoidCallback> get voiceCommands;

  bool get speakScreenWelcome => true;
  bool get autoStartVoiceListening => true;
  bool get restartListeningAfterUnknownCommand => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (speakScreenWelcome) {
        await TtsHelper.speak(screenWelcome);
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted ||
          !autoStartVoiceListening ||
          _autoListeningStarted ||
          voiceListening) {
        return;
      }
      _autoListeningStarted = true;
      await toggleVoiceListening();
    });
  }

  @override
  void dispose() {
    voiceService.stopListening();
    super.dispose();
  }

  Future<void> toggleVoiceListening() async {
    if (voiceListening) {
      await stopVoiceListening();
      return;
    }

    if (!mounted) return;
    setState(() {
      voiceListening = true;
      voicePartialResult = null;
    });
    await TtsHelper.speak(listeningPrompt);

    final locale = SettingsService.language == 'Arabic' ? 'ar-SA' : 'en-US';
    try {
      await voiceService.startListening(
        localeId: locale,
        onResult: (text, isFinal) {
          if (!mounted) return;
          setState(() => voicePartialResult = text);
          if (isFinal && text.isNotEmpty) _dispatch(text.toLowerCase().trim());
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        voiceListening = false;
        voicePartialResult = null;
      });
    }
  }

  Future<void> stopVoiceListening({bool clearPartial = true}) async {
    await voiceService.stopListening();
    if (!mounted) return;
    setState(() {
      voiceListening = false;
      if (clearPartial) voicePartialResult = null;
    });
  }

  Future<void> restartVoiceListeningSoon({
    Duration delay = const Duration(milliseconds: 900),
  }) async {
    await Future<void>.delayed(delay);
    if (!mounted || voiceListening) return;
    await toggleVoiceListening();
  }

  void _dispatch(String spoken) {
    setState(() {
      voiceListening = false;
      voicePartialResult = null;
    });
    voiceService.stopListening();

    for (final entry in voiceCommands.entries) {
      if (entry.key.any((phrase) => spoken.contains(phrase))) {
        entry.value();
        return;
      }
    }

    TtsHelper.speak(notUnderstoodText).then((_) {
      if (restartListeningAfterUnknownCommand) restartVoiceListeningSoon();
    });
  }

  String get listeningPrompt => SettingsService.language == 'Arabic'
      ? '\u0623\u0646\u0627 \u0623\u0633\u062a\u0645\u0639. \u064a\u0631\u062c\u0649 \u0642\u0648\u0644 \u0623\u0645\u0631.'
      : 'Listening. Please say a command.';

  String get voiceIdleHint => SettingsService.language == 'Arabic'
      ? '\u0627\u0636\u063a\u0637 \u0639\u0644\u0649 \u0627\u0644\u0645\u064a\u0643\u0631\u0648\u0641\u0648\u0646 \u0644\u0644\u062a\u062d\u062f\u062b'
      : 'Tap mic to speak a command';

  String get notUnderstoodText => SettingsService.language == 'Arabic'
      ? '\u0644\u0645 \u0623\u0641\u0647\u0645. \u0647\u0644 \u064a\u0645\u0643\u0646\u0643 \u0625\u0639\u0627\u062f\u0629 \u0645\u0627 \u0642\u0644\u062a\u061f'
      : 'I did not understand. Can you repeat what you said?';
}
