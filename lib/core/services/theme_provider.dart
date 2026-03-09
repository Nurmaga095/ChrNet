import 'package:flutter/material.dart';
import 'storage_service.dart';

class ThemeProvider extends ChangeNotifier {
  late ThemeMode _themeMode;

  ThemeProvider() {
    _themeMode = StorageService.getThemeMode();
  }

  ThemeMode get themeMode => _themeMode;

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    await StorageService.setThemeMode(mode);
    notifyListeners();
  }
}
