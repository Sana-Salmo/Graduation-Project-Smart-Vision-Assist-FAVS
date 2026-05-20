import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/locale/locale_notifier.dart';
import '../../core/utils/tts_helper.dart';
import '../../core/utils/voice_enabled_mixin.dart';
import '../../l10n/app_localizations.dart';
import '../../services/fl_sample_collector.dart';
import '../../services/settings_service.dart';
import '../../widgets/voice_bar.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with VoiceEnabledMixin {
  // ── VoiceEnabledMixin contract ─────────────────────────────────────────────

  @override
  String get screenWelcome {
    final name = AppLocalizations.of(context)!.settings;
    final hint = SettingsService.language == 'Arabic'
        ? 'قل: إنجليزية، أو عربية، للتبديل. قل رجوع للعودة.'
        : 'Say: English, or Arabic, to switch language. Say back to return.';
    return '$name. $hint';
  }

  @override
  Map<List<String>, VoidCallback> get voiceCommands => {
    ['english', 'إنجليزية', 'انجليزية']: () => _onLanguageChanged('English'),
    ['arabic', 'عربية', 'عربي']: () => _onLanguageChanged('Arabic'),
    ['back', 'home', 'رجوع', 'الرئيسية']: () => Navigator.pop(context),
  };

  // initState provided by VoiceEnabledMixin.

  late String _language;
  late String _voiceSpeed;
  late double _alertVolume;
  bool _accessibilityMode = false;
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  int _flSampleCount = 0;
  bool _flEnabled = false;
  bool _flUpdateReady = false;
  bool _isSyncing = false;
  Timer? _contactSyncDebounce;
  StreamSubscription<int>? _flSampleCountSubscription;

  @override
  void initState() {
    super.initState();
    _language = SettingsService.language;
    _voiceSpeed = SettingsService.speedLabel(SettingsService.voiceSpeed);
    _alertVolume = SettingsService.alertVolume;
    _flEnabled = SettingsService.federatedLearningEnabled;
    _nameController = TextEditingController(text: SettingsService.contactName);
    _phoneController = TextEditingController(
      text: SettingsService.contactPhone,
    );

    _nameController.addListener(() {
      SettingsService.setContactName(_nameController.text);
      _scheduleContactSync();
    });
    _phoneController.addListener(() {
      SettingsService.setContactPhone(_phoneController.text);
      _scheduleContactSync();
    });

    _loadFlCount();
    _flSampleCountSubscription = FlSampleCollector.instance.sampleCountStream
        .listen((_) => _loadFlCount());
  }

  Future<void> _loadFlCount() async {
    final count = await FlSampleCollector.instance.getSampleCount();
    final updateReady = await FlSampleCollector.instance.hasReadyLocalUpdate();
    if (mounted) {
      setState(() {
        _flSampleCount = count;
        _flUpdateReady = updateReady;
      });
    }
  }

  @override
  void dispose() {
    _contactSyncDebounce?.cancel();
    _flSampleCountSubscription?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _scheduleContactSync() {
    _contactSyncDebounce?.cancel();
    _contactSyncDebounce = Timer(const Duration(milliseconds: 700), () {
      SettingsService.syncToFirestore().catchError((_) {});
    });
  }

  Future<void> _onLanguageChanged(String val) async {
    await SettingsService.setLanguage(val);
    await TtsHelper.refreshLanguageFromSettings();
    LocaleNotifier.setLocale(val);
    if (!mounted) return;
    setState(() => _language = val);
    await TtsHelper.speak(
      val == 'Arabic'
          ? 'تم تغيير اللغة إلى العربية.'
          : 'Language changed to English.',
    );
  }

  Future<void> _onVoiceSpeedChanged(String label) async {
    setState(() => _voiceSpeed = label);
    final rate = SettingsService.speedRate(label);
    await SettingsService.setVoiceSpeed(rate);
    await TtsHelper.setRate(rate);
  }

  Future<void> _onAlertVolumeChanged(double val) async {
    setState(() => _alertVolume = val);
    await SettingsService.setAlertVolume(val);
    await TtsHelper.setVolume(val);
  }

  Future<void> _onFlEnabledChanged(bool val) async {
    setState(() => _flEnabled = val);
    await SettingsService.setFederatedLearningEnabled(val);
    await SettingsService.syncToFirestore();
  }

  bool get _isArabic => _language == 'Arabic';

  String _tr(String en, String ar) => _isArabic ? ar : en;

  Future<void> _buildFlUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_flEnabled) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              'Enable Federated Learning before building an update.',
              '\u0641\u0639\u0651\u0644 \u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639 \u0642\u0628\u0644 \u0628\u0646\u0627\u0621 \u0627\u0644\u062a\u062d\u062f\u064a\u062b.',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _isSyncing = true);
    final update = await FlSampleCollector.instance
        .buildLocalUpdate(reason: 'manual_settings')
        .catchError((_) => null);
    if (!mounted) return;
    setState(() {
      _isSyncing = false;
      _flUpdateReady = update != null;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          update == null
              ? _tr(
                  'Collect 200 samples before building a local update.',
                  '\u0627\u062c\u0645\u0639 200 \u0639\u064a\u0646\u0629 \u0642\u0628\u0644 \u0628\u0646\u0627\u0621 \u0627\u0644\u062a\u062d\u062f\u064a\u062b \u0627\u0644\u0645\u062d\u0644\u064a.',
                )
              : _tr(
                  'Local FL update is ready.',
                  '\u062a\u062d\u062f\u064a\u062b \u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639 \u0627\u0644\u0645\u062d\u0644\u064a \u062c\u0627\u0647\u0632.',
                ),
        ),
      ),
    );
  }

  Future<void> _uploadFlUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_flEnabled) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              'Enable Federated Learning before syncing an update.',
              '\u0641\u0639\u0651\u0644 \u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639 \u0642\u0628\u0644 \u0645\u0632\u0627\u0645\u0646\u0629 \u0627\u0644\u062a\u062d\u062f\u064a\u062b.',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _isSyncing = true);
    final uploaded = await FlSampleCollector.instance
        .uploadLocalUpdateToFirebase()
        .catchError((_) => false);
    if (!mounted) return;
    final count = await FlSampleCollector.instance.getSampleCount();
    if (!mounted) return;
    setState(() {
      _isSyncing = false;
      _flSampleCount = count;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          uploaded
              ? _tr(
                  'Uploaded local FL update to Firebase.',
                  '\u062a\u0645\u062a \u0645\u0632\u0627\u0645\u0646\u0629 \u062a\u062d\u062f\u064a\u062b \u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639 \u0625\u0644\u0649 Firebase.',
                )
              : count >= kFlRoundSampleThreshold
              ? _tr(
                  'Could not sync update. Check sign-in, network, or Firestore.',
                  '\u062a\u0639\u0630\u0631\u062a \u0645\u0632\u0627\u0645\u0646\u0629 \u0627\u0644\u062a\u062d\u062f\u064a\u062b. \u062a\u062d\u0642\u0642 \u0645\u0646 \u062a\u0633\u062c\u064a\u0644 \u0627\u0644\u062f\u062e\u0648\u0644 \u0648\u0627\u0644\u0625\u0646\u062a\u0631\u0646\u062a \u0648Firestore.',
                )
              : _tr(
                  'No local update ready. Collect 200 samples first.',
                  '\u0644\u0627 \u064a\u0648\u062c\u062f \u062a\u062d\u062f\u064a\u062b \u0645\u062d\u0644\u064a \u062c\u0627\u0647\u0632. \u0627\u062c\u0645\u0639 200 \u0639\u064a\u0646\u0629 \u0623\u0648\u0644\u0627\u064b.',
                ),
        ),
      ),
    );
    _loadFlCount();
  }

  Future<void> _logOut() async {
    await stopVoiceListening();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    await TtsHelper.speak(
      SettingsService.language == 'Arabic'
          ? 'تم تسجيل الخروج بنجاح.'
          : 'Logged out successfully.',
    );
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.auth, (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: VoiceBar(voice: this),
      appBar: AppBar(
        title: Text(
          l10n.settings,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          _SectionHeader(l10n.language),
          _ChoiceRow(
            options: const ['English', 'Arabic'],
            selected: _language,
            onSelected: _onLanguageChanged,
          ),
          const SizedBox(height: 20),
          _SectionHeader(l10n.voiceSpeed),
          _ChoiceRow(
            options: const ['Slow', 'Normal', 'Fast'],
            selected: _voiceSpeed,
            onSelected: _onVoiceSpeedChanged,
          ),
          const SizedBox(height: 20),
          _SectionHeader(l10n.alertVolume),
          _SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(
                      Icons.volume_down_rounded,
                      color: AppColors.textMuted,
                    ),
                    Expanded(
                      child: Slider(
                        value: _alertVolume,
                        onChanged: _onAlertVolumeChanged,
                        activeColor: AppColors.primary,
                        inactiveColor: const Color(0xFFBBDEFB),
                      ),
                    ),
                    const Icon(
                      Icons.volume_up_rounded,
                      color: AppColors.primary,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    '${(_alertVolume * 100).round()}%',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _SectionHeader(l10n.emergencyContact),
          _SettingsCard(
            child: Column(
              children: [
                _InputField(
                  controller: _nameController,
                  label: l10n.contactName,
                  icon: Icons.person_outline_rounded,
                  keyboardType: TextInputType.name,
                ),
                const SizedBox(height: 12),
                _InputField(
                  controller: _phoneController,
                  label: l10n.phoneNumber,
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _SectionHeader(l10n.accessibilityMode),
          _SettingsCard(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.accessibilityMode,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: AppColors.textDark,
                ),
              ),
              subtitle: Text(
                l10n.accessibilityModeSubtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
              value: _accessibilityMode,
              activeThumbColor: AppColors.primary,
              onChanged: (val) => setState(() => _accessibilityMode = val),
            ),
          ),
          const SizedBox(height: 20),
          _SectionHeader(
            _tr(
              'Federated Learning',
              '\u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639',
            ),
          ),
          _SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _tr(
                      'Join Federated Learning',
                      '\u0627\u0644\u0645\u0634\u0627\u0631\u0643\u0629 \u0641\u064a \u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639',
                    ),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: AppColors.textDark,
                    ),
                  ),
                  subtitle: Text(
                    _tr(
                      'Collects uncertain frames locally. Images never leave this device.',
                      '\u064a\u062c\u0645\u0639 \u0627\u0644\u0644\u0642\u0637\u0627\u062a \u063a\u064a\u0631 \u0627\u0644\u0645\u0624\u0643\u062f\u0629 \u0645\u062d\u0644\u064a\u0627\u064b. \u0627\u0644\u0635\u0648\u0631 \u0644\u0627 \u062a\u063a\u0627\u062f\u0631 \u0647\u0630\u0627 \u0627\u0644\u062c\u0647\u0627\u0632.',
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                  value: _flEnabled,
                  activeThumbColor: AppColors.primary,
                  onChanged: _onFlEnabledChanged,
                ),
                const Divider(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(
                      Icons.model_training_rounded,
                      color: AppColors.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _tr(
                              'Local FL Samples: $_flSampleCount / $kFlRoundSampleThreshold',
                              '\u0639\u064a\u0646\u0627\u062a \u0627\u0644\u062a\u0639\u0644\u0645 \u0627\u0644\u0645\u0648\u0632\u0639: $_flSampleCount / $kFlRoundSampleThreshold',
                            ),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDark,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _flUpdateReady
                                ? _tr(
                                    'Local update ready for upload',
                                    '\u0627\u0644\u062a\u062d\u062f\u064a\u062b \u0627\u0644\u0645\u062d\u0644\u064a \u062c\u0627\u0647\u0632 \u0644\u0644\u0645\u0632\u0627\u0645\u0646\u0629',
                                  )
                                : _tr(
                                    'Local update builds after 200 samples',
                                    '\u064a\u062a\u0645 \u0628\u0646\u0627\u0621 \u0627\u0644\u062a\u062d\u062f\u064a\u062b \u0628\u0639\u062f 200 \u0639\u064a\u0646\u0629',
                                  ),
                            style: TextStyle(
                              fontSize: 12,
                              color: _flUpdateReady
                                  ? const Color(0xFF2E7D32)
                                  : AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  _tr(
                    'Performance guard: this demo uses a lite local update and syncs only when you press Sync.',
                    '\u0644\u0644\u0623\u062f\u0627\u0621: \u064a\u0633\u062a\u062e\u062f\u0645 \u0647\u0630\u0627 \u0627\u0644\u0639\u0631\u0636 \u062a\u062d\u062f\u064a\u062b\u0627\u064b \u0645\u062d\u0644\u064a\u0627\u064b \u062e\u0641\u064a\u0641\u0627\u064b \u0648\u064a\u0632\u0627\u0645\u0646 \u0641\u0642\u0637 \u0639\u0646\u062f \u0627\u0644\u0636\u063a\u0637 \u0639\u0644\u0649 \u0645\u0632\u0627\u0645\u0646\u0629.',
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSyncing || !_flEnabled
                            ? null
                            : _buildFlUpdate,
                        icon: const Icon(Icons.memory_rounded, size: 18),
                        label: Text(
                          _tr(
                            'Build Update',
                            '\u0628\u0646\u0627\u0621 \u0627\u0644\u062a\u062d\u062f\u064a\u062b',
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(color: AppColors.primary),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await FlSampleCollector.instance.clearSamples();
                          _loadFlCount();
                        },
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _tr(
                            'Clear FL Data',
                            '\u0645\u0633\u062d \u0628\u064a\u0627\u0646\u0627\u062a FL',
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isSyncing || !_flEnabled
                            ? null
                            : _uploadFlUpdate,
                        icon: _isSyncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.cloud_upload_outlined, size: 18),
                        label: Text(
                          _tr(
                            'Sync Update',
                            '\u0645\u0632\u0627\u0645\u0646\u0629 \u0627\u0644\u062a\u062d\u062f\u064a\u062b',
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionHeader('Account'),
          _SettingsCard(
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _logOut,
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Log Out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: AppColors.error),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

// ── Card wrapper ─────────────────────────────────────────────────────────────

class _SettingsCard extends StatelessWidget {
  final Widget child;
  const _SettingsCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: child,
      ),
    );
  }
}

// ── Choice chip row ──────────────────────────────────────────────────────────

class _ChoiceRow extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;

  const _ChoiceRow({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      child: Row(
        children: options.map((option) {
          final isSelected = option == selected;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () => onSelected(option),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.primary
                        : const Color(0xFFF0F4FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    option,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? Colors.white : AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Text input field ─────────────────────────────────────────────────────────

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType keyboardType;

  const _InputField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 15, color: AppColors.textDark),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
        prefixIcon: Icon(icon, color: AppColors.primary, size: 22),
        filled: true,
        fillColor: AppColors.background,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 14,
          horizontal: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.8),
        ),
      ),
    );
  }
}
