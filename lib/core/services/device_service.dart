import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_info_service.dart';
import 'storage_service.dart';

class DeviceInfo {
  /// Идентификатор устройства для подписочных серверов.
  ///
  /// Никогда не бывает пустым: если платформа не смогла сообщить свой
  /// идентификатор, подставляется сохранённый локально запасной HWID.
  final String deviceId;

  /// Название платформы: `Windows`, `Android`, `iOS`, ...
  final String platform;

  final String osVersion;
  final String model;
  final String appVersion;

  const DeviceInfo({
    required this.deviceId,
    required this.platform,
    required this.osVersion,
    required this.model,
    required this.appVersion,
  });

  String get userAgent => 'ChrNet/$appVersion ($platform)';

  /// Заголовки, по которым Remnawave и совместимые панели опознают устройство.
  ///
  /// `x-hwid` отправляется всегда — без него панель отдаёт заглушку вместо
  /// подписки.
  Map<String, String> get subscriptionHeaders => {
        'User-Agent': userAgent,
        'x-hwid': deviceId,
        'x-device-os': platform,
        if (osVersion.isNotEmpty) 'x-ver-os': osVersion,
        if (model.isNotEmpty) 'x-device-model': model,
      };
}

class DeviceService {
  static const _channel = MethodChannel('com.chrnet.vpn/service');
  static DeviceInfo? _cached;

  /// Возвращает HWID устройства, версию ОС и модель.
  ///
  /// Успешный ответ платформы кэшируется. Запасной вариант не кэшируется,
  /// чтобы более поздний удачный вызов всё-таки заменил его.
  static Future<DeviceInfo> getDeviceInfo() async {
    if (_cached != null) return _cached!;

    var deviceId = '';
    var osVersion = '';
    var model = '';
    try {
      final map =
          await _channel.invokeMapMethod<String, String>('getDeviceInfo') ?? {};
      deviceId = map['deviceId']?.trim() ?? '';
      osVersion = map['osVersion']?.trim() ?? '';
      model = map['model']?.trim() ?? '';
    } catch (_) {
      // Платформа не ответила — ниже подставится запасной HWID.
    }

    final appVersion = await AppInfoService.getVersion();
    final platform = _platformName();

    if (_isUsableHwid(deviceId)) {
      _cached = DeviceInfo(
        deviceId: deviceId,
        platform: platform,
        osVersion: osVersion,
        model: model,
        appVersion: appVersion,
      );
      return _cached!;
    }

    return DeviceInfo(
      deviceId: await _fallbackHwid(),
      platform: platform,
      osVersion: osVersion,
      model: model,
      appVersion: appVersion,
    );
  }

  /// Сбрасывает кэш. Нужен только тестам.
  @visibleForTesting
  static void resetCache() => _cached = null;

  /// Заголовок допускает только видимые ASCII-символы, поэтому кириллическое
  /// имя ПК или мусор из платформенного канала использовать нельзя.
  static bool _isUsableHwid(String value) {
    if (value.isEmpty) return false;
    if (value.length > 128) return false;
    return RegExp(r'^[\x21-\x7E]+$').hasMatch(value);
  }

  /// HWID, сгенерированный один раз и сохранённый на устройстве.
  ///
  /// Так делают остальные клиенты: сервер получает стабильный идентификатор
  /// даже там, где ОС его не отдаёт.
  static Future<String> _fallbackHwid() async {
    try {
      final stored = StorageService.getFallbackHwid();
      if (stored != null && _isUsableHwid(stored)) return stored;

      final generated = _randomUuid();
      await StorageService.setFallbackHwid(generated);
      return generated;
    } catch (_) {
      // Хранилище недоступно (например, в тестах) — HWID проживёт один сеанс.
      return _randomUuid();
    }
  }

  static String _randomUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // версия 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // вариант RFC 4122

    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static String _platformName() {
    if (kIsWeb) return 'Web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.linux:
        return 'Linux';
      default:
        return 'Unknown';
    }
  }
}
