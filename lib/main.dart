import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'core/config/app_config.dart';
import 'core/constants/app_routes.dart';
import 'core/locale/locale_notifier.dart';
import 'core/theme/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/splash/splash_screen.dart';
import 'screens/welcome/welcome_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/emergency/emergency_screen.dart';
import 'screens/obstacle_detection/obstacle_detection_screen.dart';
import 'screens/ocr/ocr_screen.dart';
import 'screens/scene_description/scene_description_screen.dart';
import 'screens/navigation/navigation_screen.dart';
import 'services/federated_learning_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await AppConfig.load();
  await SettingsService.init();
  LocaleNotifier.init();
  unawaited(FederatedLearningService.instance.initialize());
  runApp(const SmartVisionApp());
}

class SmartVisionApp extends StatefulWidget {
  const SmartVisionApp({super.key});

  @override
  State<SmartVisionApp> createState() => _SmartVisionAppState();
}

class _SmartVisionAppState extends State<SmartVisionApp> {
  @override
  void initState() {
    super.initState();
    LocaleNotifier.instance.addListener(_onLocaleChange);
  }

  @override
  void dispose() {
    LocaleNotifier.instance.removeListener(_onLocaleChange);
    super.dispose();
  }

  void _onLocaleChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Vision Assist',
      theme: AppTheme.light,
      locale: LocaleNotifier.instance.value,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      initialRoute: AppRoutes.splash,
      routes: {
        AppRoutes.splash: (_) => const SplashScreen(),
        AppRoutes.auth: (_) => const AuthScreen(),
        AppRoutes.welcome: (_) => const WelcomeScreen(),
        AppRoutes.home: (_) => const HomeScreen(),
        AppRoutes.settings: (_) => const SettingsScreen(),
        AppRoutes.emergency: (_) => const EmergencyScreen(),
        AppRoutes.obstacleDetection: (_) => const ObstacleDetectionScreen(),
        AppRoutes.ocr: (_) => const OcrScreen(),
        AppRoutes.sceneDescription: (_) => const SceneDescriptionScreen(),
        AppRoutes.navigation: (_) => const NavigationScreen(),
      },
    );
  }
}
