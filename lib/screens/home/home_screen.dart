import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/utils/tts_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../services/settings_service.dart';
import '../../services/voice_command_service.dart';
import '../../widgets/feature_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _voiceService = VoiceCommandService();
  bool _listening = false;
  String? _voiceHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _speakWelcome();
    });
  }

  @override
  void dispose() {
    TtsHelper.stop();
    _voiceService.stopListening();
    super.dispose();
  }

  Future<void> _speakWelcome() async {
    final l10n = AppLocalizations.of(context)!;
    await TtsHelper.speak(l10n.ttsHomeWelcome);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted && !_listening) {
      await _toggleListening();
    }
  }

  // ── Voice command listener ────────────────────────────────────────────────

  Future<void> _toggleListening() async {
    if (_listening) {
      await _voiceService.stopListening();
      if (mounted) {
        setState(() {
          _listening = false;
          _voiceHint = null;
        });
      }
      return;
    }

    setState(() {
      _listening = true;
      _voiceHint = null;
    });
    await TtsHelper.speak(AppLocalizations.of(context)!.ttsListening);

    final locale = SettingsService.language == 'Arabic' ? 'ar-SA' : 'en-US';
    try {
      await _voiceService.startListening(
        localeId: locale,
        onResult: (text, isFinal) {
          if (!mounted) return;
          setState(() => _voiceHint = text);
          if (isFinal && text.isNotEmpty) {
            _handleVoiceCommand(text.toLowerCase().trim());
          }
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _listening = false;
          _voiceHint = null;
        });
      }
    }
  }

  void _handleVoiceCommand(String command) {
    setState(() {
      _listening = false;
      _voiceHint = null;
    });
    _voiceService.stopListening();

    String? route;

    // English keywords
    if (_matches(command, ['navigation', 'navigate', 'directions', 'map'])) {
      route = AppRoutes.navigation;
    } else if (_matches(command, [
      'detection',
      'detect',
      'obstacle',
      'obstacles',
      'sensor',
    ])) {
      route = AppRoutes.obstacleDetection;
    } else if (_matches(command, ['read', 'text', 'ocr', 'scan', 'reading'])) {
      route = AppRoutes.ocr;
    } else if (_matches(command, [
      'scene',
      'describe',
      'description',
      'image',
      'picture',
    ])) {
      route = AppRoutes.sceneDescription;
    } else if (_matches(command, ['emergency', 'help', 'call', 'sos'])) {
      route = AppRoutes.emergency;
    } else if (_matches(command, [
      'settings',
      'setting',
      'config',
      '\u0625\u0639\u062f\u0627\u062f\u0627\u062a',
      '\u0627\u0639\u062f\u0627\u062f\u0627\u062a',
      '\u0627\u0644\u0625\u0639\u062f\u0627\u062f\u0627\u062a',
      '\u0627\u0644\u0627\u0639\u062f\u0627\u062f\u0627\u062a',
    ])) {
      route = AppRoutes.settings;
    }
    // Arabic keywords
    else if (_matches(command, ['ملاحة', 'توجيه', 'اتجاهات'])) {
      route = AppRoutes.navigation;
    } else if (_matches(command, ['كشف', 'عوائق', 'عائق', 'اكتشاف'])) {
      route = AppRoutes.obstacleDetection;
    } else if (_matches(command, ['قراءة', 'نص', 'مسح'])) {
      route = AppRoutes.ocr;
    } else if (_matches(command, ['وصف', 'مشهد', 'صورة'])) {
      route = AppRoutes.sceneDescription;
    } else if (_matches(command, ['طوارئ', 'مساعدة', 'نجدة'])) {
      route = AppRoutes.emergency;
    }

    if (route != null && mounted) {
      Navigator.pushNamed(context, route);
    } else if (mounted) {
      TtsHelper.speak(
        AppLocalizations.of(context)!.ttsCommandNotUnderstood,
      ).then((_) => _restartListeningSoon());
    }
  }

  Future<void> _restartListeningSoon() async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted && !_listening) {
      await _toggleListening();
    }
  }

  bool _matches(String command, List<String> keywords) {
    final normalizedCommand = _normalizeVoiceText(command);
    return keywords.any(
      (keyword) => normalizedCommand.contains(_normalizeVoiceText(keyword)),
    );
  }

  String _normalizeVoiceText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\u064b-\u065f]'), '')
        .replaceAll('\u0623', '\u0627')
        .replaceAll('\u0625', '\u0627')
        .replaceAll('\u0622', '\u0627')
        .replaceAll('\u0649', '\u064a')
        .replaceAll('\u0629', '\u0647')
        .trim();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Header(),
              const SizedBox(height: 20),
              // Mic button — always visible so the user can tap to navigate
              _MicButton(
                listening: _listening,
                voiceHint: _voiceHint,
                onTap: _toggleListening,
              ),
              const SizedBox(height: 24),
              _FeatureGrid(),
              const SizedBox(height: 20),
              _emergencyButton(context, l10n),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.visibility, size: 56, color: Colors.white),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.appName,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.homeTagline,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            color: AppColors.textMuted,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _MicButton extends StatelessWidget {
  final bool listening;
  final String? voiceHint;
  final VoidCallback onTap;

  const _MicButton({
    required this.listening,
    required this.voiceHint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      label: listening ? l10n.stopListening : l10n.tapToSpeak,
      child: Column(
        children: [
          GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: listening ? AppColors.error : AppColors.primary,
                boxShadow: [
                  BoxShadow(
                    color: (listening ? AppColors.error : AppColors.primary)
                        .withValues(alpha: 0.35),
                    blurRadius: listening ? 20 : 8,
                    spreadRadius: listening ? 4 : 1,
                  ),
                ],
              ),
              child: Icon(
                listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            voiceHint ?? (listening ? l10n.listeningEllipsis : l10n.tapToSpeak),
            style: TextStyle(
              fontSize: 13,
              color: listening ? AppColors.error : AppColors.textMuted,
              fontStyle: voiceHint != null
                  ? FontStyle.normal
                  : FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final features = [
      _Feature(
        label: l10n.obstacleDetection,
        icon: Icons.sensors,
        route: AppRoutes.obstacleDetection,
        iconColor: const Color(0xFF1565C0),
      ),
      _Feature(
        label: l10n.readText,
        icon: Icons.text_fields_rounded,
        route: AppRoutes.ocr,
        iconColor: const Color(0xFF00796B),
      ),
      _Feature(
        label: l10n.sceneDescription,
        icon: Icons.image_search_rounded,
        route: AppRoutes.sceneDescription,
        iconColor: const Color(0xFF6A1B9A),
      ),
      _Feature(
        label: l10n.navigation,
        icon: Icons.navigation_rounded,
        route: AppRoutes.navigation,
        iconColor: const Color(0xFFE65100),
      ),
    ];

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.0,
      children: features
          .map(
            (f) => FeatureCard(
              label: f.label,
              icon: f.icon,
              iconColor: f.iconColor,
              onTap: () => Navigator.pushNamed(context, f.route),
            ),
          )
          .toList(),
    );
  }
}

Widget _emergencyButton(BuildContext context, AppLocalizations l10n) {
  return Column(
    children: [
      Semantics(
        button: true,
        label: l10n.emergencyTitle,
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => Navigator.pushNamed(context, AppRoutes.emergency),
            icon: const Icon(Icons.emergency_rounded, size: 28),
            label: Text(
              l10n.emergency,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 3,
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Semantics(
        button: true,
        label: l10n.settings,
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pushNamed(context, AppRoutes.settings),
            icon: const Icon(Icons.settings_rounded, size: 24),
            label: Text(l10n.settings, style: const TextStyle(fontSize: 16)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textDark,
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: Color(0xFFBDBDBD)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _Feature {
  final String label;
  final IconData icon;
  final String route;
  final Color iconColor;

  const _Feature({
    required this.label,
    required this.icon,
    required this.route,
    required this.iconColor,
  });
}
