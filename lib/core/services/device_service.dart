import 'package:flutter/services.dart';

class DeviceInfo {
  final String deviceId;
  final String osVersion;
  final String model;

  DeviceInfo({
    required this.deviceId,
    required this.osVersion,
    required this.model,
  });
}

class DeviceService {
  static const _channel = MethodChannel('com.chrnet.vpn/service');
  static DeviceInfo? _cached;

  /// Возвращает информацию об устройстве: HWID (Android ID), версию ОС и модель.
  /// Результат кэшируется после первого вызова.
  static Future<DeviceInfo> getDeviceInfo() async {
    if (_cached != null) return _cached!;
    try {
      final map = await _channel.invokeMapMethod<String, String>('getDeviceInfo') ?? {};
      _cached = DeviceInfo(
        deviceId: map['deviceId'] ?? '',
        osVersion: map['osVersion'] ?? '',
        model: map['model'] ?? '',
      );
    } catch (_) {
      _cached = DeviceInfo(deviceId: '', osVersion: '', model: '');
    }
    return _cached!;
  }
}
