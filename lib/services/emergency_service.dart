import 'package:url_launcher/url_launcher.dart';
import 'settings_service.dart';

class EmergencyService {
  static const _defaultMessage =
      'I need help! This is an emergency alert from Smart Vision Assist.';

  /// Opens the default SMS app pre-filled with [phone] and [message].
  /// Returns true if the app launched successfully.
  static Future<bool> sendSms({String? message}) async {
    final phone = SettingsService.contactPhone.trim();
    if (phone.isEmpty) return false;
    final uri = Uri(
      scheme: 'sms',
      path: phone,
      queryParameters: {'body': message ?? _defaultMessage},
    );
    return launchUrl(uri);
  }

  /// Opens the dialer pre-filled with the saved emergency contact number.
  /// Returns true if the dialer launched successfully.
  static Future<bool> call() async {
    final phone = SettingsService.contactPhone.trim();
    if (phone.isEmpty) return false;
    final uri = Uri(scheme: 'tel', path: phone);
    return launchUrl(uri);
  }
}
