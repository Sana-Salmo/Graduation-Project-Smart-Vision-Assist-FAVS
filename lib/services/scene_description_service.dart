import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'gemini_api_client.dart';
import 'settings_service.dart';

class SceneDescriptionService {
  static const _maxImageDimension = 1024;

  static Future<String> describe(File imageFile) async {
    final bytes = await _resizedBytes(imageFile);
    final base64Image = base64Encode(bytes);
    final mimeType = _mimeType(imageFile.path);

    try {
      var result = _cleanDescription(
        await _describeWithGemini(
          prompt: _promptFor(SettingsService.language),
          mimeType: mimeType,
          base64Image: base64Image,
        ),
      );

      if (result.length < 140) {
        result = _cleanDescription(
          await _describeWithGemini(
            prompt: _retryPromptFor(SettingsService.language),
            mimeType: mimeType,
            base64Image: base64Image,
          ),
        );
      }
      return result;
    } on GeminiApiException catch (e) {
      throw SceneDescriptionException(_friendlyGeminiError(e.message));
    }
  }

  static Future<String> _describeWithGemini({
    required String prompt,
    required String mimeType,
    required String base64Image,
  }) {
    return GeminiApiClient.generateContent(
      tag: 'SceneDescription',
      temperature: 0.2,
      maxOutputTokens: 1600,
      parts: [
        {'text': prompt},
        {
          'inlineData': {'mimeType': mimeType, 'data': base64Image},
        },
      ],
    );
  }

  static String _cleanDescription(String text) {
    return text
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll(RegExp(r'#+\s*'), '')
        .replaceAll(
          RegExp(r'^\s*(okay|sure|certainly)[,!.\s]+', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();
  }

  static Future<List<int>> _resizedBytes(File imageFile) async {
    final raw = await imageFile.readAsBytes();
    final decoded = img.decodeImage(raw);
    if (decoded == null) return raw;

    final needsResize =
        decoded.width > _maxImageDimension ||
        decoded.height > _maxImageDimension;
    if (!needsResize) return raw;

    final resized = img.copyResize(
      decoded,
      width: decoded.width > decoded.height ? _maxImageDimension : -1,
      height: decoded.height >= decoded.width ? _maxImageDimension : -1,
      interpolation: img.Interpolation.linear,
    );
    return img.encodeJpg(resized, quality: 85);
  }

  static String _mimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  static String _promptFor(String language) {
    if (language == 'Arabic') {
      return '\u0623\u0646\u062a \u0645\u0633\u0627\u0639\u062f \u0628\u0635\u0631\u064a \u0644\u0634\u062e\u0635 \u0643\u0641\u064a\u0641. '
          '\u0635\u0641 \u0627\u0644\u0635\u0648\u0631\u0629 \u0628\u0627\u0644\u062a\u0641\u0635\u064a\u0644 \u0627\u0644\u0639\u0645\u0644\u064a \u0628\u0627\u0644\u0644\u063a\u0629 \u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u0641\u0642\u0637. '
          '\u0627\u0643\u062a\u0628 \u0641\u0642\u0631\u0629 \u0648\u0627\u062d\u062f\u0629 \u0645\u0646 \u062b\u0645\u0627\u0646\u064a \u0625\u0644\u0649 \u0639\u0634\u0631 \u062c\u0645\u0644 \u0642\u0635\u064a\u0631\u0629 \u0648\u0645\u0641\u064a\u062f\u0629. '
          '\u0627\u0630\u0643\u0631 \u0627\u0644\u0645\u0643\u0627\u0646 \u0627\u0644\u0639\u0627\u0645\u060c \u0648\u0627\u0644\u0623\u0634\u064a\u0627\u0621 \u0627\u0644\u0631\u0626\u064a\u0633\u064a\u0629 \u0648\u0645\u0648\u0627\u0642\u0639\u0647\u0627 \u064a\u0645\u064a\u0646\u0627\u064b \u0648\u064a\u0633\u0627\u0631\u0627\u064b \u0648\u0641\u064a \u0627\u0644\u0648\u0633\u0637\u060c '
          '\u0648\u0627\u0644\u0646\u0635\u0648\u0635 \u0627\u0644\u0638\u0627\u0647\u0631\u0629 \u0625\u0646 \u0648\u062c\u062f\u062a\u060c \u0648\u0627\u0644\u0623\u0644\u0648\u0627\u0646 \u0623\u0648 \u0627\u0644\u0623\u062d\u062c\u0627\u0645 \u0627\u0644\u0645\u0647\u0645\u0629\u060c \u0648\u0623\u064a \u0639\u0648\u0627\u0626\u0642 \u0623\u0648 \u0645\u062e\u0627\u0637\u0631 \u0642\u0631\u064a\u0628\u0629. '
          '\u0644\u0627 \u062a\u0633\u062a\u062e\u062f\u0645 Markdown\u060c \u0648\u0644\u0627 \u062a\u0628\u062f\u0623 \u0628\u0639\u0628\u0627\u0631\u0627\u062a \u0645\u062b\u0644 \u0623\u0647\u0644\u0627\u064b \u0623\u0648 \u0628\u0627\u0644\u062a\u0623\u0643\u064a\u062f.';
    }
    return 'You are a visual assistant for a blind user. Describe the image in detailed, practical English only. '
        'Write one spoken paragraph with 8 to 10 short useful sentences. Mention the overall setting, '
        'the main objects and where they are located on the left, center, and right, any readable text, '
        'important colors or sizes, and any nearby obstacles or hazards. Do not use Markdown. '
        'Do not start with phrases like okay, sure, or certainly.';
  }

  static String _retryPromptFor(String language) {
    if (language == 'Arabic') {
      return '${_promptFor(language)} \u0627\u0644\u0648\u0635\u0641 \u0627\u0644\u0633\u0627\u0628\u0642 \u0643\u0627\u0646 \u0642\u0635\u064a\u0631\u0627\u064b \u062c\u062f\u0627\u064b. '
          '\u0623\u0639\u062f \u0627\u0644\u0645\u062d\u0627\u0648\u0644\u0629 \u0628\u062a\u0641\u0627\u0635\u064a\u0644 \u0645\u0631\u0626\u064a\u0629 \u0623\u0643\u062b\u0631\u060c \u0648\u0644\u0627 \u062a\u0639\u0637 \u0639\u0646\u0648\u0627\u0646\u0627\u064b \u0641\u0642\u0637.';
    }
    return '${_promptFor(language)} The previous description was too short. Try again with more concrete visible details, not just a title.';
  }

  static String _friendlyGeminiError(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    final isServiceBusy =
        lower.contains('503') ||
        lower.contains('unavailable') ||
        lower.contains('high demand') ||
        lower.contains('try again later');

    if (SettingsService.language == 'Arabic') {
      return isServiceBusy
          ? '\u0627\u0644\u062e\u062f\u0645\u0629 \u0645\u0634\u063a\u0648\u0644\u0629 \u062d\u0627\u0644\u064a\u0627\u064b. \u062d\u0627\u0648\u0644 \u0645\u0631\u0629 \u0623\u062e\u0631\u0649 \u0628\u0639\u062f \u0644\u062d\u0638\u0627\u062a.'
          : '\u062a\u0639\u0630\u0631 \u0648\u0635\u0641 \u0627\u0644\u0645\u0634\u0647\u062f \u0627\u0644\u0622\u0646. \u064a\u0631\u062c\u0649 \u0627\u0644\u0645\u062d\u0627\u0648\u0644\u0629 \u0645\u0631\u0629 \u0623\u062e\u0631\u0649.';
    }

    return isServiceBusy
        ? 'The AI service is busy right now. Please try again in a few moments.'
        : 'Scene description is unavailable right now. Please try again.';
  }
}

class SceneDescriptionException implements Exception {
  final String message;
  const SceneDescriptionException(this.message);

  @override
  String toString() => 'SceneDescriptionException: $message';
}
