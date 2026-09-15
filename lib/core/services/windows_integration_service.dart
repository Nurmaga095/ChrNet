import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows-only integration the native runner serves on the VPN service
/// channel: starting with Windows and the state of the ChrNet service.
class WindowsIntegrationService {
  const WindowsIntegrationService._();

  static const _channel = MethodChannel('com.chrnet.vpn/service');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<bool> getLaunchAtStartup() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('getLaunchAtStartup') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns whether Windows accepted the change.
  static Future<bool> setLaunchAtStartup(bool enabled) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setLaunchAtStartup',
            {'enabled': enabled},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the ChrNet service answers. Tunnel mode needs it unless the app
  /// itself runs with administrator rights.
  static Future<({bool available, bool elevated})> getServiceInfo() async {
    if (!isSupported) return (available: false, elevated: false);
    try {
      final info =
          await _channel.invokeMapMethod<String, dynamic>('getServiceInfo');
      return (
        available: info?['available'] == true,
        elevated: info?['elevated'] == true,
      );
    } catch (_) {
      return (available: false, elevated: false);
    }
  }
}
