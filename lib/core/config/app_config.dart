import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  AppConfig._();

  // Demo fallback only. Prefer --dart-define or .env for normal development.
  static const _demoGeminiApiKey = 'AIzaSyBFI88ashOjqwF3TW-ca81fuP8EL64gFi0';

  static Future<void> load() async {
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {
      // Allow running without a local .env when values are injected via
      // --dart-define or the file is not present in development.
    }
  }

  static String get geminiApiKey {
    const fromDefine = String.fromEnvironment(
      'GEMINI_API_KEY',
      defaultValue: '',
    );
    if (fromDefine.trim().isNotEmpty) return fromDefine.trim();

    final fromEnv = dotenv.env['GEMINI_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) return fromEnv.trim();

    return _demoGeminiApiKey;
  }

  static bool get hasGeminiApiKey => geminiApiKey.trim().isNotEmpty;

  static String get obstacleModelAsset => const String.fromEnvironment(
    'OBSTACLE_MODEL_ASSET',
    defaultValue: 'assets/ml/efficientdet_lite0.tflite',
  );

  static String get obstacleLabelsAsset => const String.fromEnvironment(
    'OBSTACLE_LABELS_ASSET',
    defaultValue: 'assets/ml/coco-labels-2014_2017.txt',
  );
}
