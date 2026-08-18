import 'package:flutter/foundation.dart';

import '../core/services/storage_service.dart';

/// Runtime switch for the app's continuous animations.
///
/// Nothing in the UI blurs any more, so the remaining cost is looping
/// animations — chiefly the halo around the connect button, which the app sits
/// in for hours at a time. On a low-end phone that alone is a measurable drain,
/// and some users simply prefer a still interface.
///
/// Android defaults to reduced motion; desktop keeps the full set. The user can
/// override either way from Settings.
class AppPerf extends ChangeNotifier {
  static final AppPerf instance = AppPerf._();

  AppPerf._() : _override = StorageService.getLiteEffects();

  bool? _override;

  static bool get _platformDefault =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  /// Whether looping, purely decorative animations should be skipped.
  bool get reducedMotion => _override ?? _platformDefault;

  /// `null` when the platform default is in effect.
  bool? get override => _override;

  bool get isPlatformDefault => _override == null;

  Future<void> setOverride(bool? value) async {
    if (_override == value) return;
    _override = value;
    await StorageService.setLiteEffects(value);
    notifyListeners();
  }
}
