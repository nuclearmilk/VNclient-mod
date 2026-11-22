import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_provider.dart';

/// Persisted locale preference.
class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier(this._prefs)
      : super(Locale(_prefs.getString(_key) ?? 'zh'));

  final SharedPreferences _prefs;

  static const _key = 'app_locale';

  Future<void> setLocale(Locale locale) async {
    state = locale;
    await _prefs.setString(_key, locale.languageCode);
  }
}

final localeNotifierProvider =
    StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier(ref.watch(sharedPreferencesProvider));
});

/// Supported app languages.
const supportedLocales = <Locale>[
  Locale('zh'),
  Locale('en'),
  Locale('ja'),
];
