// The app's own settings, kept on the phone (shared_preferences).
// Only Dark mode for now. Rain alerts are not stored here: they follow the
// phone's notification permission for RubberTap.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';

class AppPrefs {
  AppPrefs._();

  static const _darkKey = 'dark_mode';

  /// main.dart listens to this and rebuilds the whole app when it changes.
  static final ValueNotifier<bool> darkMode = ValueNotifier<bool>(false);

  /// Read the saved settings once, before the first screen is shown.
  /// Never throws: a storage problem must not stop the app from starting.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      darkMode.value = prefs.getBool(_darkKey) ?? false;
    } catch (_) {}
    AppColors.dark = darkMode.value;
  }

  static Future<void> setDarkMode(bool on) async {
    AppColors.dark = on;
    darkMode.value = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_darkKey, on);
    } catch (_) {}
  }
}
