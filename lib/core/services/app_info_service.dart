import 'package:package_info_plus/package_info_plus.dart';

class AppInfoService {
  static String? _cachedVersion;

  static Future<String> getVersion() async {
    if (_cachedVersion != null) {
      return _cachedVersion!;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      _cachedVersion = version.isEmpty || version.toLowerCase() == 'unknown'
          ? 'unknown'
          : version;
    } catch (_) {
      _cachedVersion = 'unknown';
    }

    return _cachedVersion!;
  }
}
