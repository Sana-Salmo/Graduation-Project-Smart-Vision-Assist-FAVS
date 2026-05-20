import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class VoiceCommandService {
  final SpeechToText _speech = SpeechToText();

  bool get isListening => _speech.isListening;

  Future<bool> initialize() async {
    return _speech.initialize();
  }

  Future<void> startListening({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  }) async {
    if (!_speech.isAvailable) {
      final available = await initialize();
      if (!available) {
        throw const VoiceCommandException('Speech recognition is unavailable.');
      }
    }

    await _speech.listen(
      localeId: localeId,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
      ),
      onResult: (SpeechRecognitionResult result) {
        onResult(result.recognizedWords, result.finalResult);
      },
    );
  }

  Future<void> stopListening() async {
    await _speech.stop();
  }
}

class VoiceCommandException implements Exception {
  final String message;
  const VoiceCommandException(this.message);

  @override
  String toString() => 'VoiceCommandException: $message';
}
