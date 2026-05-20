import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/config/app_config.dart';

class GeminiApiClient {
  GeminiApiClient._();

  static const _baseUrl = 'https://generativelanguage.googleapis.com/v1';
  static const _model = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.5-flash',
  );
  static const _fallbackModels = [
    _model,
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash',
    'gemini-2.0-flash-lite',
  ];

  static Future<String> generateContent({
    required List<Map<String, dynamic>> parts,
    double temperature = 0.3,
    int maxOutputTokens = 768,
    String tag = 'Gemini',
  }) async {
    if (!AppConfig.hasGeminiApiKey) {
      throw const GeminiApiException(
        'Gemini API key is missing. Add GEMINI_API_KEY to .env, use --dart-define, or set the demo fallback.',
      );
    }

    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': maxOutputTokens,
      },
    });

    GeminiApiException? lastQuotaOrNotFound;
    for (final model in _dedupeModels(_fallbackModels)) {
      try {
        return await _postToModel(
          model: model,
          body: body,
          tag: tag,
        );
      } on GeminiApiException catch (e) {
        if (e.retryableWithFallback) {
          lastQuotaOrNotFound = e;
          continue;
        }
        rethrow;
      }
    }

    throw lastQuotaOrNotFound ??
        const GeminiApiException('Gemini request failed for all models.');
  }

  static Future<String> _postToModel({
    required String model,
    required String body,
    required String tag,
  }) async {
    final uri = Uri.parse('$_baseUrl/models/$model:generateContent');

    late http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': AppConfig.geminiApiKey,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 35));
    } catch (e) {
      throw GeminiApiException('Network error: $e');
    }

    if (response.statusCode == 429) {
      debugPrint('[$tag] Gemini quota exceeded for $model: ${response.body}');
      throw const GeminiApiException(
        'AI quota exceeded for this key. Use a fresh Google AI Studio key with billing/quota enabled, then rebuild.',
        retryableWithFallback: true,
      );
    }

    if (response.statusCode == 404) {
      debugPrint('[$tag] Gemini model not found for $model: ${response.body}');
      throw GeminiApiException(
        'Gemini model "$model" is not available on v1 for this key. Run ListModels for this key or set GEMINI_MODEL to an available v1 model.',
        retryableWithFallback: true,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint('[$tag] Gemini HTTP ${response.statusCode}: ${response.body}');
      throw GeminiApiException(
        'Gemini API error ${response.statusCode}: ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = _extractText(decoded);
    if (text == null || text.trim().isEmpty) {
      throw const GeminiApiException('Gemini returned an empty response.');
    }
    return text.trim();
  }

  static List<String> _dedupeModels(List<String> models) {
    final seen = <String>{};
    return [
      for (final model in models)
        if (model.trim().isNotEmpty && seen.add(model.trim())) model.trim(),
    ];
  }

  static String? _extractText(Map<String, dynamic> json) {
    try {
      final candidates = json['candidates'] as List<dynamic>;
      final content = candidates.first['content'] as Map<String, dynamic>;
      final parts = content['parts'] as List<dynamic>;
      return parts
          .map((part) => (part as Map<String, dynamic>)['text'])
          .whereType<String>()
          .join('\n')
          .trim();
    } catch (_) {
      return null;
    }
  }
}

class GeminiApiException implements Exception {
  final String message;
  final bool retryableWithFallback;
  const GeminiApiException(
    this.message, {
    this.retryableWithFallback = false,
  });

  @override
  String toString() => 'GeminiApiException: $message';
}
