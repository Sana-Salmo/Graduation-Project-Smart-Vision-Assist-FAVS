import 'package:flutter/material.dart';
import '../../services/settings_service.dart';

/// Drives [MaterialApp.locale] at runtime without state management libraries.
/// Call [init] once in main() after SettingsService.init().
/// Call [setLocale] whenever the user changes the language in Settings.
class LocaleNotifier extends ValueNotifier<Locale> {
  LocaleNotifier._() : super(const Locale('en'));

  static final instance = LocaleNotifier._();

  static void init() {
    instance.value = _localeFor(SettingsService.language);
  }

  static void setLocale(String language) {
    instance.value = _localeFor(language);
  }

  static Locale _localeFor(String language) =>
      language == 'Arabic' ? const Locale('ar') : const Locale('en');
}
