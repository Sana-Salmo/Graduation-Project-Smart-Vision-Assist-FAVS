import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _kLanguage = 'language';
  static const _kVoiceSpeed = 'voiceSpeed';
  static const _kAlertVolume = 'alertVolume';
  static const _kContactName = 'contactName';
  static const _kContactPhone = 'contactPhone';
  static const _kFederatedLearningEnabled = 'federatedLearningEnabled';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ── Getters (return defaults when nothing is saved yet) ──────────────────

  static String get language => _prefs?.getString(_kLanguage) ?? 'English';
  static double get voiceSpeed => _prefs?.getDouble(_kVoiceSpeed) ?? 0.45;
  static double get alertVolume => _prefs?.getDouble(_kAlertVolume) ?? 0.7;
  static String get contactName => _prefs?.getString(_kContactName) ?? '';
  static String get contactPhone => _prefs?.getString(_kContactPhone) ?? '';
  static bool get federatedLearningEnabled =>
      _prefs?.getBool(_kFederatedLearningEnabled) ?? false;

  /// BCP-47 code ready for TtsHelper.setLanguage().
  static String get ttsLanguageCode => language == 'Arabic' ? 'ar-SA' : 'en-US';

  /// UI label → rate double. Inverse of [speedLabel].
  static double speedRate(String label) {
    switch (label) {
      case 'Slow':
        return 0.3;
      case 'Fast':
        return 0.65;
      default:
        return 0.45;
    }
  }

  /// Stored rate double → UI label. Inverse of [speedRate].
  static String speedLabel(double rate) {
    if (rate <= 0.35) return 'Slow';
    if (rate >= 0.55) return 'Fast';
    return 'Normal';
  }

  // ── Setters ───────────────────────────────────────────────────────────────

  static Future<void> setLanguage(String val) async =>
      _prefs?.setString(_kLanguage, val);

  static Future<void> setVoiceSpeed(double val) async =>
      _prefs?.setDouble(_kVoiceSpeed, val);

  static Future<void> setAlertVolume(double val) async =>
      _prefs?.setDouble(_kAlertVolume, val);

  static Future<void> setContactName(String val) async =>
      _prefs?.setString(_kContactName, val);

  static Future<void> setContactPhone(String val) async =>
      _prefs?.setString(_kContactPhone, val);

  static Future<void> setFederatedLearningEnabled(bool val) async =>
      _prefs?.setBool(_kFederatedLearningEnabled, val);

  // ── Firestore sync ────────────────────────────────────────────────────────

  /// Writes current local settings to Firestore under `users/{uid}/settings`.
  /// Silent no-op when the user is not signed in.
  static Future<void> syncToFirestore() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('settings')
        .doc('prefs')
        .set({
          _kLanguage: language,
          _kVoiceSpeed: voiceSpeed,
          _kAlertVolume: alertVolume,
          _kContactName: contactName,
          _kContactPhone: contactPhone,
          _kFederatedLearningEnabled: federatedLearningEnabled,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  /// Loads settings from Firestore into shared_preferences (call after login).
  static Future<void> loadFromFirestore() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('settings')
          .doc('prefs')
          .get();
      if (!doc.exists) return;
      final data = doc.data()!;
      if (data[_kLanguage] is String)
        await setLanguage(data[_kLanguage] as String);
      if (data[_kVoiceSpeed] is double)
        await setVoiceSpeed(data[_kVoiceSpeed] as double);
      if (data[_kAlertVolume] is double)
        await setAlertVolume(data[_kAlertVolume] as double);
      if (data[_kContactName] is String)
        await setContactName(data[_kContactName] as String);
      if (data[_kContactPhone] is String)
        await setContactPhone(data[_kContactPhone] as String);
      if (data[_kFederatedLearningEnabled] is bool) {
        await setFederatedLearningEnabled(
          data[_kFederatedLearningEnabled] as bool,
        );
      }
    } catch (_) {
      // Firestore unavailable — local prefs remain authoritative.
    }
  }
}
