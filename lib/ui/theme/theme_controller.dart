import 'package:flutter/material.dart';

import '../../core/services/storage_service.dart';

/// The app's light/dark preference, persisted across launches.
///
/// A plain [ChangeNotifier] singleton rather than a provider so that
/// `MaterialApp` can listen to it before the provider tree exists, and so
/// settings can flip the theme without a `BuildContext`.
class AppThemeController extends ChangeNotifier {
  static final AppThemeController instance = AppThemeController._();

  AppThemeController._() : _mode = _decode(StorageService.getThemeMode());

  ThemeMode _mode;

  ThemeMode get mode => _mode;

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    await StorageService.setThemeMode(_encode(mode));
    notifyListeners();
  }

  static ThemeMode _decode(String raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String _encode(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
}
