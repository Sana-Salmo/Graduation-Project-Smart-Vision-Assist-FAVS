import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import '../core/config/app_config.dart';
import 'gemini_api_client.dart';
import 'settings_service.dart';

class OcrService {
  static const _maxImageDimension = 1024;

  static Future<String> extractText(File imageFile) async {
    if (SettingsService.language == 'Arabic') {
      return _extractArabicText(imageFile);
    }
    return _extractEnglishText(imageFile);
  }

  static Future<String> _extractEnglishText(File imageFile) async {
    final rawText = await _extractWithMlKit(imageFile);

    if (!AppConfig.hasGeminiApiKey || rawText.trim().isEmpty) {
      return rawText;
    }

    try {
      return await _addEnglishContext(rawText);
    } on GeminiApiException catch (e) {
      final friendly = _friendlyGeminiError(e.message);
      if (friendly != null) throw OcrException(friendly);
      return rawText;
    } catch (_) {
      return rawText;
    }
  }

  static Future<String> _extractWithMlKit(File imageFile) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final result = await recognizer.processImage(inputImage);
      return result.text.trim();
    } catch (e) {
      throw OcrException('ML Kit error: $e');
    } finally {
      await recognizer.close();
    }
  }

  static Future<String> _addEnglishContext(String rawText) {
    const prompt = '''You are an OCR assistant for a visually impaired person.
You have been given raw text extracted from an image. Your job is to:
1. In ONE short sentence, identify the document type.
2. If a page number or chapter heading is visible, mention it naturally.
3. Then read the text naturally with no markdown.

Keep your response concise and spoken-language friendly.

Raw extracted text:
''';

    return GeminiApiClient.generateContent(
      tag: 'OCR-context',
      temperature: 0.2,
      maxOutputTokens: 768,
      parts: [
        {'text': '$prompt$rawText'},
      ],
    );
  }

  static Future<String> _extractArabicText(File imageFile) async {
    if (!AppConfig.hasGeminiApiKey) {
      throw const OcrException(
        'Gemini API key is missing. Add GEMINI_API_KEY to .env, use --dart-define, or set the demo fallback.',
      );
    }

    final bytes = await _resizedBytes(imageFile);
    final base64Image = base64Encode(bytes);
    final mimeType = _mimeType(imageFile.path);

    try {
      return await GeminiApiClient.generateContent(
        tag: 'OCR-arabic',
        temperature: 0.0,
        maxOutputTokens: 1024,
        parts: [
          {
            'text':
                'أنت مساعد للمكفوفين. في جملة واحدة قصيرة، أخبر '
                'المستخدم بنوع المحتوى، مثل صفحة كتاب أو شاشة هاتف أو لافتة. '
                'ثم استخرج كل النص الموجود في الصورة بدقة واقرأه بشكل طبيعي.',
          },
          {
            'inlineData': {'mimeType': mimeType, 'data': base64Image},
          },
        ],
      );
    } on GeminiApiException catch (e) {
      throw OcrException(_friendlyGeminiError(e.message) ?? e.message);
    }
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

  static String? _friendlyGeminiError(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    final isServiceBusy =
        lower.contains('503') ||
        lower.contains('unavailable') ||
        lower.contains('high demand') ||
        lower.contains('try again later');
    if (!isServiceBusy) return null;

    if (SettingsService.language == 'Arabic') {
      return '\u0627\u0644\u062e\u062f\u0645\u0629 \u0645\u0634\u063a\u0648\u0644\u0629 \u062d\u0627\u0644\u064a\u064b\u0627\u060c \u062d\u0627\u0648\u0644 \u0645\u0631\u0629 \u0623\u062e\u0631\u0649 \u0628\u0639\u062f \u0644\u062d\u0638\u0627\u062a.';
    }
    return 'The AI service is busy right now. Please try again in a few moments.';
  }
}

class OcrException implements Exception {
  final String message;
  const OcrException(this.message);

  @override
  String toString() => 'OcrException: $message';
}
