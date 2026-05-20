import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/utils/tts_helper.dart';
import '../../core/utils/voice_enabled_mixin.dart';
import '../../l10n/app_localizations.dart';
import '../../services/emergency_service.dart';
import '../../services/settings_service.dart';
import '../../widgets/voice_bar.dart';

class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen>
    with VoiceEnabledMixin {
  // ── VoiceEnabledMixin contract ─────────────────────────────────────────────

  @override
  String get screenWelcome {
    final l10n = AppLocalizations.of(context)!;
    final hint = SettingsService.language == 'Arabic'
        ? 'قل: إرسال، للتنبيه. قل اتصال، للاتصال. قل رجوع للعودة.'
        : 'Say: send alert, or call, to contact your emergency contact. Say back to return.';
    return '${l10n.emergencyTitle}. $hint';
  }

  @override
  Map<List<String>, VoidCallback> get voiceCommands => {
    ['send', 'alert', 'إرسال', 'تنبيه']: _sendAlert,
    ['call', 'اتصال', 'اتصل']: _callContact,
    ['back', 'home', 'رجوع', 'الرئيسية']: () => Navigator.pop(context),
  };

  // initState provided by VoiceEnabledMixin; it speaks screenWelcome then
  // we chain our own setup via super.initState() below.

  bool _alertSent = false;
  late String _contactName;
  late String _contactPhone;

  @override
  void initState() {
    super.initState(); // mixin speaks welcome
    _loadContact();
  }

  @override
  void dispose() {
    TtsHelper.stop();
    super.dispose();
  }

  void _loadContact() {
    _contactName = SettingsService.contactName;
    _contactPhone = SettingsService.contactPhone;
  }

  bool get _hasContact => _contactPhone.trim().isNotEmpty;

  Future<void> _sendAlert() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_hasContact) {
      _showNoContactError(l10n);
      return;
    }
    final launched = await EmergencyService.sendSms();
    if (!mounted) return;
    if (launched) {
      setState(() => _alertSent = true);
      _showSnackBar(
        l10n.alertSent,
        Icons.check_circle_rounded,
        const Color(0xFF388E3C),
      );
    } else {
      _showSnackBar(
        l10n.couldNotOpenSms,
        Icons.error_outline_rounded,
        AppColors.error,
      );
    }
  }

  Future<void> _callContact() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_hasContact) {
      _showNoContactError(l10n);
      return;
    }
    final launched = await EmergencyService.call();
    if (!mounted) return;
    if (launched) {
      _showSnackBar(l10n.callInitiated, Icons.phone_rounded, AppColors.primary);
    } else {
      _showSnackBar(
        l10n.couldNotOpenDialer,
        Icons.error_outline_rounded,
        AppColors.error,
      );
    }
  }

  void _showNoContactError(AppLocalizations l10n) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.noContactError,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFFE65100),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: l10n.settings,
          textColor: Colors.white,
          onPressed: () =>
              Navigator.pushNamed(context, AppRoutes.settings).then((_) {
                setState(_loadContact);
              }),
        ),
      ),
    );
  }

  void _showSnackBar(String text, IconData icon, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
          ],
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: VoiceBar(voice: this),
      appBar: AppBar(
        title: Text(
          l10n.emergencyTitle,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.error,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _WarningHeader(hasContact: _hasContact),
              const SizedBox(height: 28),
              _StatusCard(alertSent: _alertSent),
              const SizedBox(height: 32),
              _SendAlertButton(alertSent: _alertSent, onPressed: _sendAlert),
              const SizedBox(height: 16),
              _CallContactButton(onPressed: _callContact),
              const SizedBox(height: 32),
              _TrustedContactCard(
                name: _contactName,
                phone: _contactPhone,
                onGoToSettings: () => Navigator.pushNamed(
                  context,
                  AppRoutes.settings,
                ).then((_) => setState(_loadContact)),
              ),
              const SizedBox(height: 16),
              _DisclaimerText(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Warning header ───────────────────────────────────────────────────────────

class _WarningHeader extends StatelessWidget {
  final bool hasContact;
  const _WarningHeader({required this.hasContact});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: AppColors.error.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.emergency_rounded,
            size: 64,
            color: AppColors.error,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.emergencyTitle,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            hasContact
                ? l10n.emergencySubtitle
                : l10n.emergencyNoContactSubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: hasContact ? AppColors.textMuted : AppColors.error,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Status card ──────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final bool alertSent;
  const _StatusCard({required this.alertSent});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusColor = alertSent ? const Color(0xFF388E3C) : AppColors.error;
    final statusLabel = alertSent ? l10n.alertSentLabel : l10n.statusReady;
    final statusIcon = alertSent ? Icons.check_circle_rounded : Icons.circle;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.sensors_rounded, size: 36, color: statusColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.systemStatus,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(statusIcon, size: 12, color: statusColor),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Send alert button ────────────────────────────────────────────────────────

class _SendAlertButton extends StatelessWidget {
  final bool alertSent;
  final VoidCallback onPressed;
  const _SendAlertButton({required this.alertSent, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = alertSent ? l10n.alertSentLabel : l10n.sendAlert;
    return Semantics(
      button: true,
      label: l10n.sendAlert,
      hint: 'Opens SMS app with emergency message pre-filled',
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: alertSent ? null : onPressed,
          icon: Icon(
            alertSent ? Icons.check_rounded : Icons.send_rounded,
            size: 28,
          ),
          label: Text(
            label,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: alertSent
                ? const Color(0xFF388E3C)
                : AppColors.error,
            disabledBackgroundColor: const Color(0xFF388E3C),
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            elevation: alertSent ? 0 : 4,
          ),
        ),
      ),
    );
  }
}

// ── Call contact button ──────────────────────────────────────────────────────

class _CallContactButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _CallContactButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      label: l10n.callContact,
      hint: 'Opens phone dialer with emergency contact number',
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.phone_rounded, size: 24),
          label: Text(
            l10n.callContact,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 16),
            side: const BorderSide(color: AppColors.primary, width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Trusted contact card ─────────────────────────────────────────────────────

class _TrustedContactCard extends StatelessWidget {
  final String name;
  final String phone;
  final VoidCallback onGoToSettings;

  const _TrustedContactCard({
    required this.name,
    required this.phone,
    required this.onGoToSettings,
  });

  bool get _isEmpty => name.trim().isEmpty && phone.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.contact_phone_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.trustedContact,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: AppColors.primary,
                  ),
                ),
              ),
              if (_isEmpty)
                GestureDetector(
                  onTap: onGoToSettings,
                  child: Text(
                    l10n.addInSettings,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 16),
          if (_isEmpty)
            Text(
              l10n.noContactSaved,
              style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
            )
          else ...[
            _ContactRow(
              icon: Icons.person_rounded,
              value: name.isEmpty ? '—' : name,
            ),
            const SizedBox(height: 8),
            _ContactRow(icon: Icons.phone_rounded, value: phone),
          ],
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String value;
  const _ContactRow({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: 10),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            color: AppColors.textDark,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── Disclaimer ───────────────────────────────────────────────────────────────

class _DisclaimerText extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text(
      AppLocalizations.of(context)!.updateContactHint,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 13,
        color: AppColors.textMuted,
        height: 1.5,
      ),
    );
  }
}
